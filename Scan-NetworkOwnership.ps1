[CmdletBinding()]
param(
    [string]$AdapterPath = '',
    [string]$PathHealthScript = '',
    [string]$OutputDirectory = '',
    [ValidateRange(2, 30)]
    [int]$ProbeTimeoutSeconds = 6,
    [switch]$SkipPathHealth,
    [switch]$SelfTest,
    [switch]$PassThru,
    [switch]$NoWriteReport,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Version = '0.4.3-beta'
$Script:Warnings = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($AdapterPath)) {
    $AdapterPath = Join-Path $PSScriptRoot 'client_adapters.json'
}
if ([string]::IsNullOrWhiteSpace($PathHealthScript)) {
    $PathHealthScript = Join-Path $PSScriptRoot 'Test-NetworkPathHealth.ps1'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'reports'
}

function Add-ScanWarning {
    param([string]$Message)
    if (-not $Script:Warnings.Contains($Message)) {
        $Script:Warnings.Add($Message)
    }
}

function ConvertTo-RedactedProxyValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $safe = $Value -replace '(?i)(https?://|socks5?://)[^/@\s]+@', '$1***@'
    return $safe
}

function Get-LocalEndpoint {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $match = [regex]::Match(
        $Value,
        '(?i)(?:https?=|socks=)?(?:https?://|socks5?://)?(?<host>127\.0\.0\.1|localhost|\[::1\]|::1)\s*:\s*(?<port>\d{1,5})'
    )
    if (-not $match.Success) { return $null }

    return [pscustomobject]@{
        Host = $match.Groups['host'].Value
        Port = [int]$match.Groups['port'].Value
        Text = '127.0.0.1:{0}' -f [int]$match.Groups['port'].Value
    }
}

function Test-PatternList {
    param([string]$Text, $Patterns)
    foreach ($pattern in @($Patterns)) {
        if ($Text -match [string]$pattern) { return $true }
    }
    return $false
}

function Get-ObjectPropertyValue {
    param($Object, [string]$Name, $DefaultValue = $null)
    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Test-ProcessRoleMatch {
    param($Process, $NamePatterns, $PathPatterns = @())
    if ($null -eq $Process) { return $false }
    $name = [string](Get-ObjectPropertyValue -Object $Process -Name 'Name' -DefaultValue '')
    if (-not (Test-PatternList -Text $name -Patterns $NamePatterns)) { return $false }
    $requiredPaths = @($PathPatterns)
    if ($requiredPaths.Count -eq 0) { return $true }
    $path = [string](Get-ObjectPropertyValue -Object $Process -Name 'Path' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    return (Test-PatternList -Text $path -Patterns $requiredPaths)
}

function Get-ClientForProcess {
    param($Process, $Adapters)
    foreach ($adapter in $Adapters) {
        $uiPaths = @(Get-ObjectPropertyValue -Object $adapter -Name 'uiPathPatterns' -DefaultValue @())
        $corePaths = @(Get-ObjectPropertyValue -Object $adapter -Name 'corePathPatterns' -DefaultValue @())
        $helperPaths = @(Get-ObjectPropertyValue -Object $adapter -Name 'helperPathPatterns' -DefaultValue @())
        if (
            (Test-ProcessRoleMatch -Process $Process -NamePatterns $adapter.uiProcessPatterns -PathPatterns $uiPaths) -or
            (Test-ProcessRoleMatch -Process $Process -NamePatterns $adapter.coreProcessPatterns -PathPatterns $corePaths) -or
            (Test-ProcessRoleMatch -Process $Process -NamePatterns $adapter.helperProcessPatterns -PathPatterns $helperPaths)
        ) {
            return $adapter
        }
    }
    return $null
}

function Get-ClientForProcessName {
    param([string]$ProcessName, $Adapters, [string]$ProcessPath = '')
    return Get-ClientForProcess -Process ([pscustomobject]@{ Name=$ProcessName; Path=$ProcessPath }) -Adapters $Adapters
}

function Get-Adapters {
    if (-not (Test-Path -LiteralPath $AdapterPath)) {
        throw "客户端适配器文件不存在：$AdapterPath"
    }
    return @(Get-Content -LiteralPath $AdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ProcessSnapshot {
    $rows = New-Object System.Collections.Generic.List[object]
    $commandLines = @{}
    try {
        foreach ($item in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $commandLines[[int]$item.ProcessId] = [string]$item.CommandLine
        }
    }
    catch { Add-ScanWarning "无法读取进程命令行，客户端 IPC 诊断将降级：$($_.Exception.Message)" }
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = ''
        try { $path = [string]$process.Path } catch {}
        $rows.Add([pscustomobject]@{
            Id = [int]$process.Id
            Name = [string]$process.ProcessName
            Path = $path
            CommandLine = if ($commandLines.ContainsKey([int]$process.Id)) { $commandLines[[int]$process.Id] } else { '' }
            StartTimeUtc = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { '' })
            SessionId = $(try { [int]$process.SessionId } catch { -1 })
        })
    }
    return $rows.ToArray()
}

function Get-ControlPortFromCommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $match = [regex]::Match($CommandLine, '(?:^|\s)(?<port>\d{2,5})\s*$')
    if (-not $match.Success) { return $null }
    $port = [int]$match.Groups['port'].Value
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    return $port
}

function Get-ServiceSnapshot {
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($service in @(Get-Service -ErrorAction SilentlyContinue)) {
            $startType = ''
            try { $startType = [string]$service.StartType } catch {}
            $rows.Add([pscustomobject]@{
                Name = [string]$service.Name
                DisplayName = [string]$service.DisplayName
                Status = [string]$service.Status
                StartType = $startType
            })
        }
    }
    catch {
        Add-ScanWarning "无法读取 Windows 服务：$($_.Exception.Message)"
    }
    return $rows.ToArray()
}

function Get-TcpListeners {
    param($Processes)
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            $process = $Processes | Where-Object { $_.Id -eq [int]$item.OwningProcess } | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                Protocol = 'TCP'
                Address = [string]$item.LocalAddress
                Port = [int]$item.LocalPort
                Pid = [int]$item.OwningProcess
                Process = if ($null -ne $process) { $process.Name } else { '未知' }
            })
        }
        return $rows.ToArray()
    }
    catch {
        Add-ScanWarning "Get-NetTCPConnection 不可用，已回退到 netstat：$($_.Exception.Message)"
    }

    try {
        foreach ($line in @(& netstat.exe -ano -p tcp 2>$null)) {
            if ($line -notmatch '^\s*TCP\s+(?<address>\S+):(?<port>\d+)\s+\S+\s+LISTENING\s+(?<pid>\d+)') { continue }
            $pidValue = [int]$Matches['pid']
            $process = $Processes | Where-Object { $_.Id -eq $pidValue } | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                Protocol = 'TCP'
                Address = [string]$Matches['address']
                Port = [int]$Matches['port']
                Pid = $pidValue
                Process = if ($null -ne $process) { $process.Name } else { '未知' }
            })
        }
    }
    catch {
        Add-ScanWarning "无法读取 TCP 监听端口：$($_.Exception.Message)"
    }
    return $rows.ToArray()
}

function Get-UdpListeners {
    param($Processes)
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in @(Get-NetUDPEndpoint -ErrorAction Stop)) {
            $process = $Processes | Where-Object { $_.Id -eq [int]$item.OwningProcess } | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                Protocol = 'UDP'
                Address = [string]$item.LocalAddress
                Port = [int]$item.LocalPort
                Pid = [int]$item.OwningProcess
                Process = if ($null -ne $process) { $process.Name } else { '未知' }
            })
        }
    }
    catch {
        Add-ScanWarning "无法读取 UDP 监听端口：$($_.Exception.Message)"
    }
    return $rows.ToArray()
}

function Get-SystemProxySnapshot {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $proxyEnableProperty = $item.PSObject.Properties['ProxyEnable']
        $proxyServerProperty = $item.PSObject.Properties['ProxyServer']
        $proxyOverrideProperty = $item.PSObject.Properties['ProxyOverride']
        $autoConfigProperty = $item.PSObject.Properties['AutoConfigURL']
        $proxyEnable = if ($null -ne $proxyEnableProperty) { [int]$proxyEnableProperty.Value } else { 0 }
        $server = if ($null -ne $proxyServerProperty) { [string]$proxyServerProperty.Value } else { '' }
        $override = if ($null -ne $proxyOverrideProperty) { [string]$proxyOverrideProperty.Value } else { '' }
        return [pscustomobject]@{
            Readable = $true
            Enabled = ($proxyEnable -eq 1)
            Server = ConvertTo-RedactedProxyValue $server
            Override = $override
            AutoConfigUrl = if ($null -ne $autoConfigProperty) { ConvertTo-RedactedProxyValue ([string]$autoConfigProperty.Value) } else { '' }
            Endpoint = Get-LocalEndpoint $server
        }
    }
    catch {
        Add-ScanWarning "无法读取当前用户系统代理：$($_.Exception.Message)"
        return [pscustomobject]@{ Readable = $false; Enabled = $false; Server = ''; Override = ''; AutoConfigUrl = ''; Endpoint = $null }
    }
}

function Get-WinHttpSnapshot {
    $raw = ''
    try { $raw = ((& netsh.exe winhttp show proxy 2>&1) -join "`n").Trim() } catch {
        Add-ScanWarning "无法读取 WinHTTP 代理：$($_.Exception.Message)"
    }
    return [pscustomobject]@{
        Raw = ConvertTo-RedactedProxyValue $raw
        Endpoint = Get-LocalEndpoint $raw
        Direct = ($raw -match '(?i)Direct access|直接访问|无代理')
    }
}

function Get-EnvironmentProxySnapshot {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('Process', 'User', 'Machine')) {
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $rows.Add([pscustomobject]@{
                Scope = $scope
                Name = $name
                Value = ConvertTo-RedactedProxyValue $value
                Endpoint = Get-LocalEndpoint $value
            })
        }
    }
    return $rows.ToArray()
}

function Get-NetworkSnapshot {
    $adapters = @()
    $routes = @()
    $dns = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Select-Object Name, InterfaceDescription, InterfaceIndex, Status, MacAddress, LinkSpeed)
    }
    catch { Add-ScanWarning "无法读取网卡：$($_.Exception.Message)" }
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Select-Object DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, State)
    }
    catch { Add-ScanWarning "无法读取 IPv4 路由：$($_.Exception.Message)" }
    try {
        $dns = @(Get-DnsClientServerAddress -ErrorAction Stop |
            Where-Object { @($_.ServerAddresses).Count -gt 0 } |
            Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses)
    }
    catch { Add-ScanWarning "无法读取 DNS：$($_.Exception.Message)" }
    return [pscustomobject]@{ Adapters = $adapters; Routes = $routes; Dns = $dns }
}

function Get-ProxyGuardStatus {
    param($Adapter)
    $keys = @($Adapter.proxyGuardKeys)
    if ($keys.Count -eq 0) { return '不适用' }
    $checked = 0
    foreach ($rootTemplate in @($Adapter.configRoots)) {
        $root = [Environment]::ExpandEnvironmentVariables([string]$rootTemplate)
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 2MB -and $_.Extension -match '^\.(json|ya?ml|toml|conf|ini)$' } |
            Select-Object -First 200)
        foreach ($file in $files) {
            $checked++
            try {
                $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                foreach ($key in $keys) {
                    $escaped = [regex]::Escape([string]$key)
                    $guardPattern = '(?im)\b' + $escaped + '\b[^\r\n:=]{0,4}[:=]\s*(true|1|on|enabled)'
                    if ($content -match $guardPattern) {
                        return '已开启'
                    }
                }
            }
            catch {}
        }
    }
    if ($checked -gt 0) { return '未发现开启证据' }
    return '未检查到配置文件'
}

function Get-ClientSnapshot {
    param($Adapters, $Processes, $Services, $Listeners)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in $Adapters) {
        $uiPaths = @(Get-ObjectPropertyValue -Object $adapter -Name 'uiPathPatterns' -DefaultValue @())
        $corePaths = @(Get-ObjectPropertyValue -Object $adapter -Name 'corePathPatterns' -DefaultValue @())
        $helperPaths = @(Get-ObjectPropertyValue -Object $adapter -Name 'helperPathPatterns' -DefaultValue @())
        $ui = @($Processes | Where-Object { Test-ProcessRoleMatch -Process $_ -NamePatterns $adapter.uiProcessPatterns -PathPatterns $uiPaths })
        $core = @($Processes | Where-Object { Test-ProcessRoleMatch -Process $_ -NamePatterns $adapter.coreProcessPatterns -PathPatterns $corePaths })
        $helper = @($Processes | Where-Object { Test-ProcessRoleMatch -Process $_ -NamePatterns $adapter.helperProcessPatterns -PathPatterns $helperPaths })
        $service = @($Services | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties.Name -contains 'Name' -and
            (Test-PatternList -Text ([string]$_.Name) -Patterns $adapter.servicePatterns)
        })
        $uiIds = @($ui | ForEach-Object { $_.Id })
        $coreIds = @($core | ForEach-Object { $_.Id })
        $helperIds = @($helper | ForEach-Object { $_.Id })
        $processIds = $uiIds + $coreIds + $helperIds
        $ownedListeners = @($Listeners | Where-Object { $processIds -contains $_.Pid })
        $coreListeners = @($Listeners | Where-Object { $coreIds -contains $_.Pid })
        $helperListeners = @($Listeners | Where-Object { $helperIds -contains $_.Pid })
        $configRoots = @(Get-ObjectPropertyValue -Object $adapter -Name 'configRoots' -DefaultValue @())
        $installed = @($configRoots | Where-Object {
            Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables([string]$_))
        }).Count -gt 0
        $defaultProxyPorts = @(Get-ObjectPropertyValue -Object $adapter -Name 'defaultProxyPorts' -DefaultValue @())
        $proxyCapabilities = @(Get-ObjectPropertyValue -Object $adapter -Name 'proxyCapabilities' -DefaultValue @())
        $safeStopPatterns = @(Get-ObjectPropertyValue -Object $adapter -Name 'safeStopProcessPatterns' -DefaultValue (
            @($adapter.uiProcessPatterns) + @($adapter.coreProcessPatterns) + @($adapter.helperProcessPatterns)
        ))
        $runtimeFamily = [string](Get-ObjectPropertyValue -Object $adapter -Name 'runtimeFamily' -DefaultValue 'independent')
        $sharedControlPorts = @(Get-ObjectPropertyValue -Object $adapter -Name 'sharedControlPorts' -DefaultValue @())
        $controlPortFromCoreArgs = [bool](Get-ObjectPropertyValue -Object $adapter -Name 'controlPortFromCoreArgs' -DefaultValue $false)
        $controlPorts = New-Object System.Collections.Generic.List[int]
        if ($controlPortFromCoreArgs) {
            foreach ($coreProcess in $core) {
                $controlPort = Get-ControlPortFromCommandLine -CommandLine ([string]$coreProcess.CommandLine)
                if ($null -ne $controlPort -and -not $controlPorts.Contains([int]$controlPort)) { $controlPorts.Add([int]$controlPort) }
            }
        }
        $controlPortListeners = @($Listeners | Where-Object {
            $_.Protocol -eq 'TCP' -and $controlPorts.Contains([int]$_.Port) -and $_.Address -in @('127.0.0.1','0.0.0.0','::1','::','[::]')
        })
        $ipcBroken = ($controlPortFromCoreArgs -and $core.Count -gt 0 -and $controlPorts.Count -gt 0 -and $controlPortListeners.Count -eq 0)
        $rows.Add([pscustomobject]@{
            Id = [string]$adapter.id
            Name = [string]$adapter.name
            UiProcesses = @($ui | Select-Object Id, Name, Path, CommandLine, StartTimeUtc, SessionId)
            CoreProcesses = @($core | Select-Object Id, Name, Path, CommandLine, StartTimeUtc, SessionId)
            HelperProcesses = @($helper | Select-Object Id, Name, Path, CommandLine, StartTimeUtc, SessionId)
            Services = @($service | Select-Object Name, Status, StartType)
            Listeners = @($ownedListeners | Select-Object Protocol, Address, Port, Pid, Process)
            CoreListeners = @($coreListeners | Select-Object Protocol, Address, Port, Pid, Process)
            HelperListeners = @($helperListeners | Select-Object Protocol, Address, Port, Pid, Process)
            ProxyGuard = Get-ProxyGuardStatus -Adapter $adapter
            TunInterfacePatterns = @($adapter.tunInterfacePatterns)
            DefaultProxyPorts = @($defaultProxyPorts | ForEach-Object { [int]$_ })
            ProxyCapabilities = @($proxyCapabilities | ForEach-Object { [string]$_ })
            SafeStopProcessPatterns = @($safeStopPatterns | ForEach-Object { [string]$_ })
            RuntimeFamily = $runtimeFamily
            SharedControlPorts = @($sharedControlPorts | ForEach-Object { [int]$_ })
            ControlPortFromCoreArgs = $controlPortFromCoreArgs
            ControlPorts = @($controlPorts.ToArray())
            ControlPortListeners = @($controlPortListeners | Select-Object Protocol, Address, Port, Pid, Process)
            IpcBroken = $ipcBroken
            Installed = $installed
            Running = (($ui.Count + $core.Count + $helper.Count) -gt 0)
            HasCoreEvidence = ($core.Count -gt 0 -or $coreListeners.Count -gt 0)
        })
    }
    return $rows.ToArray()
}

function Resolve-ListenerOwner {
    param($Endpoint, $Listeners, $Adapters, $Processes)
    if ($null -eq $Endpoint) { return $null }
    $listener = $Listeners | Where-Object {
        $_.Port -eq $Endpoint.Port -and $_.Address -in @('127.0.0.1', '0.0.0.0', '::1', '::', '[::]')
    } | Select-Object -First 1
    if ($null -eq $listener) { return $null }
    $process = $Processes | Where-Object { $_.Id -eq [int]$listener.Pid } | Select-Object -First 1
    if ($null -eq $process) { $process = [pscustomobject]@{ Name=[string]$listener.Process; Path='' } }
    $client = Get-ClientForProcess -Process $process -Adapters $Adapters
    return [pscustomobject]@{
        ClientId = if ($null -ne $client) { [string]$client.id } else { 'unknown' }
        Client = if ($null -ne $client) { [string]$client.name } else { '未知客户端' }
        Process = [string]$listener.Process
        Pid = [int]$listener.Pid
        Port = [int]$listener.Port
        Evidence = '本地端口监听 PID'
    }
}

function Get-TunOwners {
    param($Network, $Adapters, $Clients)
    $rows = New-Object System.Collections.Generic.List[object]
    $defaultRoutes = @($Network.Routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
    foreach ($route in $defaultRoutes) {
        $adapterRow = $Network.Adapters | Where-Object { $_.InterfaceIndex -eq $route.InterfaceIndex } | Select-Object -First 1
        $description = if ($null -ne $adapterRow) { "$($adapterRow.Name) $($adapterRow.InterfaceDescription)" } else { [string]$route.InterfaceAlias }
        $isTunLike = ($route.NextHop -like '198.18.*')
        $matchingAdapters = @($Adapters | Where-Object { Test-PatternList -Text $description -Patterns $_.tunInterfacePatterns })
        if ($matchingAdapters.Count -gt 0) { $isTunLike = $true }
        $activeMatches = @($matchingAdapters | Where-Object {
            $clientId = [string]$_.id
            $client = $Clients | Where-Object { $_.Id -eq $clientId } | Select-Object -First 1
            $null -ne $client -and (@($client.UiProcesses).Count -gt 0 -or @($client.CoreProcesses).Count -gt 0)
        })
        $owner = if ($activeMatches.Count -eq 1) {
            $activeMatches[0]
        }
        elseif ($activeMatches.Count -eq 0 -and $matchingAdapters.Count -eq 1) {
            $matchingAdapters[0]
        }
        else {
            $null
        }
        if (-not $isTunLike) { continue }
        $rows.Add([pscustomobject]@{
            ClientId = if ($null -ne $owner) { [string]$owner.id } else { 'unknown' }
            Client = if ($null -ne $owner) { [string]$owner.name } else { '未知客户端' }
            InterfaceAlias = [string]$route.InterfaceAlias
            InterfaceIndex = [int]$route.InterfaceIndex
            NextHop = [string]$route.NextHop
            Metric = [int]$route.RouteMetric
            Evidence = 'TUN 默认路由'
        })
    }
    return $rows.ToArray()
}

function Get-DnsOwnerCandidates {
    param($Network, $TunOwners, $UdpListeners, $Adapters, $Processes)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($dnsRow in @($Network.Dns)) {
        foreach ($server in @($dnsRow.ServerAddresses)) {
            $client = $null
            $evidence = ''
            if ($server -in @('127.0.0.1', '::1')) {
                $listener = $UdpListeners | Where-Object { $_.Port -eq 53 -and $_.Address -in @('127.0.0.1', '0.0.0.0', '::1', '::') } | Select-Object -First 1
                if ($null -ne $listener) {
                    $process = $Processes | Where-Object { $_.Id -eq [int]$listener.Pid } | Select-Object -First 1
                    if ($null -eq $process) { $process = [pscustomobject]@{ Name=[string]$listener.Process; Path='' } }
                    $client = Get-ClientForProcess -Process $process -Adapters $Adapters
                    $evidence = "本地 DNS 监听进程 $($listener.Process)"
                }
            }
            elseif ($server -like '198.18.*') {
                $tun = $TunOwners | Where-Object { $_.InterfaceIndex -eq $dnsRow.InterfaceIndex } | Select-Object -First 1
                if ($null -ne $tun) {
                    $client = $Adapters | Where-Object { $_.id -eq $tun.ClientId } | Select-Object -First 1
                    $evidence = 'DNS 地址与 TUN 接口一致'
                }
            }
            if ($null -eq $client -and [string]::IsNullOrWhiteSpace($evidence)) { continue }
            $rows.Add([pscustomobject]@{
                ClientId = if ($null -ne $client) { [string]$client.id } else { 'unknown' }
                Client = if ($null -ne $client) { [string]$client.name } else { '未知客户端' }
                InterfaceAlias = [string]$dnsRow.InterfaceAlias
                Server = [string]$server
                Evidence = $evidence
            })
        }
    }
    return $rows.ToArray()
}

function Get-PortOwnerSnapshot {
    param($Clients)
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($client in @($Clients)) {
        foreach ($listener in @($client.CoreListeners)) {
            # 同一核心可能同时监听 TCP/UDP 或 IPv4/IPv6；端口归属面向“进程 + 端口”，避免重复展示和重复确认。
            $key = '{0}|{1}|{2}' -f $client.Id, $listener.Pid, $listener.Port
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $process = $client.CoreProcesses | Where-Object { $_.Id -eq $listener.Pid } | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                ClientId = [string]$client.Id
                Client = [string]$client.Name
                Port = [int]$listener.Port
                Pid = [int]$listener.Pid
                Process = [string]$listener.Process
                StartTimeUtc = if ($null -ne $process) { [string]$process.StartTimeUtc } else { '' }
                SessionId = if ($null -ne $process) { [int]$process.SessionId } else { -1 }
                UiRunning = (@($client.UiProcesses).Count -gt 0)
                DeclaredPort = (@($client.DefaultProxyPorts) -contains [int]$listener.Port)
                Evidence = '已知客户端核心监听端口'
            })
        }
    }
    return $rows.ToArray()
}

function New-DiagnosisFinding {
    param([string]$Code, [string]$Severity, [string]$Message, [string]$Action)
    return [pscustomobject]@{ code=$Code; severity=$Severity; message=$Message; action=$Action }
}

function Get-DiagnosisSnapshot {
    param(
        $SystemProxy, $SystemProxyOwner, $TunOwners, $WinHttp, $WinHttpOwner,
        $EnvironmentProxies, $EnvironmentOwners, $Clients, $Listeners, $PortOwners,
        $OwnerIds, $PathHealth
    )
    $findings = New-Object System.Collections.Generic.List[object]
    $knownOwnerIds = @($OwnerIds | Where-Object { $_ -and $_ -ne 'unknown' } | Select-Object -Unique)
    $guardClients = @($Clients | Where-Object { $_.ProxyGuard -eq '已开启' })
    $activeFlClashClients = @($Clients | Where-Object {
        (Get-ObjectPropertyValue $_ 'RuntimeFamily' '') -eq 'flclash' -and (@($_.UiProcesses).Count -gt 0 -or @($_.CoreProcesses).Count -gt 0)
    })
    $ipcBrokenClients = @($Clients | Where-Object { [bool](Get-ObjectPropertyValue $_ 'IpcBroken' $false) })
    $staleSystemProxy = ($SystemProxy.Enabled -and $null -ne $SystemProxy.Endpoint -and $null -eq $SystemProxyOwner)
    $tunResiduals = New-Object System.Collections.Generic.List[object]
    foreach ($tun in @($TunOwners | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ClientId' -and $_.ClientId -ne 'unknown'
    })) {
        $client = $Clients | Where-Object { $_.Id -eq $tun.ClientId } | Select-Object -First 1
        if ($null -ne $client -and -not $client.HasCoreEvidence -and @($client.UiProcesses).Count -eq 0) {
            $tunResiduals.Add($tun)
        }
    }

    $systemEndpoint = if ($null -ne $SystemProxy.Endpoint) { [string]$SystemProxy.Endpoint.Text } else { '' }
    $environmentEndpointTexts = @($EnvironmentProxies | Where-Object { $null -ne $_.Endpoint } | ForEach-Object { [string]$_.Endpoint.Text } | Select-Object -Unique)
    $staleEnvironment = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($EnvironmentProxies | Where-Object { $null -ne $_.Endpoint })) {
        $hasListener = @($Listeners | Where-Object {
            $_.Protocol -eq 'TCP' -and $_.Port -eq $item.Endpoint.Port -and $_.Address -in @('127.0.0.1','0.0.0.0','::1','::','[::]')
        }).Count -gt 0
        if (-not $hasListener) { $staleEnvironment.Add($item) }
    }
    $applicationSplit = ($staleEnvironment.Count -gt 0)
    if ($SystemProxy.Enabled -and -not [string]::IsNullOrWhiteSpace($systemEndpoint)) {
        if (@($environmentEndpointTexts | Where-Object { $_ -ne $systemEndpoint }).Count -gt 0) { $applicationSplit = $true }
        if ($null -ne $WinHttp.Endpoint -and $WinHttp.Endpoint.Text -ne $systemEndpoint) { $applicationSplit = $true }
    }
    elseif (-not $SystemProxy.Enabled -and @($TunOwners | Where-Object { $null -ne $_ }).Count -eq 0 -and $environmentEndpointTexts.Count -gt 0) {
        # Windows 浏览器已转为直连，但 Codex、终端等进程仍可能使用本地代理。
        # 这种状态不能因为本地代理核心仍在运行就判定为“单一代理接管正常”。
        $applicationSplit = $true
    }
    if (@($EnvironmentOwners | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ClientId' -and
        $_.ClientId -ne 'unknown' -and $null -ne $SystemProxyOwner -and $_.ClientId -ne $SystemProxyOwner.ClientId
    }).Count -gt 0) {
        $applicationSplit = $true
    }

    $backgroundPortOwners = @($PortOwners | Where-Object {
        $uiRunning = [bool](Get-ObjectPropertyValue $_ 'UiRunning' $false)
        $declaredPort = [bool](Get-ObjectPropertyValue $_ 'DeclaredPort' $false)
        $clientId = [string](Get-ObjectPropertyValue $_ 'ClientId' '')
        -not $uiRunning -and $declaredPort -and $knownOwnerIds -notcontains $clientId
    })
    $orphanCoreOwners = @($PortOwners | Where-Object {
        -not [bool](Get-ObjectPropertyValue $_ 'UiRunning' $false) -and [bool](Get-ObjectPropertyValue $_ 'DeclaredPort' $false)
    })
    if ($activeFlClashClients.Count -gt 1) {
        $findings.Add((New-DiagnosisFinding 'SharedRuntimeConflict' '高风险' "检测到多个 FlClash 同源客户端同时运行：$($activeFlClashClients.Name -join '、')。它们可能争用共享 Helper、系统代理和控制端口。" '一键退出全部代理并恢复普通网络；确认直连后只打开一个客户端。'))
    }
    foreach ($client in $ipcBrokenClients) {
        $ports = @($client.ControlPorts) -join '、'
        $findings.Add((New-DiagnosisFinding 'ClientIpcBroken' '高风险' "$($client.Name) 的界面或核心仍在，但命令行指定的本地控制端口 $ports 无人监听。" '一键退出全部代理并恢复普通网络，然后只重新打开一个客户端。'))
    }
    foreach ($portOwner in $orphanCoreOwners) {
        $findings.Add((New-DiagnosisFinding 'OrphanCore' '高风险' "$($portOwner.Client) 的界面已退出，但核心 $($portOwner.Process)（PID $($portOwner.Pid)）仍占用 $($portOwner.Port) 端口。" '确认后一键清场，精确结束残留核心。'))
    }
    foreach ($portOwner in $backgroundPortOwners) {
        $findings.Add((New-DiagnosisFinding 'PortOccupiedByOtherClient' '中风险' "后台核心 $($portOwner.Process)（PID $($portOwner.Pid)）仍由 $($portOwner.Client) 占用 $($portOwner.Port) 端口。" '一键退出全部代理并恢复普通网络。'))
    }
    if ($applicationSplit) {
        $details = @($staleEnvironment | ForEach-Object { "$($_.Scope)/$($_.Name)=$($_.Endpoint.Text)" })
        $message = if ($details.Count -gt 0) { "发现失效或不一致的应用代理路径：$($details -join '、')。" } else { 'Windows 系统代理、WinHTTP 或应用代理环境变量指向不同接管者。' }
        $findings.Add((New-DiagnosisFinding 'ApplicationPathSplit' '高风险' $message '根据当前有效 Owner 一键同步，或清除旧的本地代理环境变量。'))
    }
    if ($tunResiduals.Count -gt 0) {
        $findings.Add((New-DiagnosisFinding 'TunResidual' '高风险' "客户端核心已退出，但 TUN 接管仍存在：$(@($tunResiduals.Client) -join '、')。" '由用户确认后定向清理已知 TUN 路由和网卡。'))
    }
    $differentTunOwners = @(if ($null -ne $SystemProxyOwner) { @($TunOwners | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ClientId' -and
        $_.ClientId -ne 'unknown' -and $_.ClientId -ne $SystemProxyOwner.ClientId
    }) } else { @() })
    if ($differentTunOwners.Count -gt 0) {
        $findings.Add((New-DiagnosisFinding 'TunConflictDetected' '高风险' "系统代理属于 $($SystemProxyOwner.Client)，TUN 属于 $($differentTunOwners[0].Client)。" '一键退出全部代理并恢复普通网络；确认直连后只打开一个客户端。'))
    }
    if ($staleSystemProxy) {
        $findings.Add((New-DiagnosisFinding 'StaleSystemProxy' '紧急' "Windows 系统代理指向 $systemEndpoint，但本地端口无人监听。" '连续确认且普通网络可用后，只关闭系统代理开关。'))
    }
    if ($guardClients.Count -gt 0) {
        $findings.Add((New-DiagnosisFinding 'ProxyGuardConflict' '中风险' "检测到客户端代理守护：$($guardClients.Name -join '、')。" '不要反复争抢代理开关；请关闭代理守护或完整退出客户端。'))
    }

    $proxyFailureCandidate = $false
    $directHealthy = $false
    $proxyHealthy = $false
    $directStatus = 'NotTested'
    $proxyStatus = 'NotTested'
    if ($null -ne $PathHealth) {
        $proxyFailureCandidate = [bool](Get-ObjectPropertyValue $PathHealth 'proxyFailureCandidate' $false)
        $direct = Get-ObjectPropertyValue $PathHealth 'direct' $null
        $proxy = Get-ObjectPropertyValue $PathHealth 'proxy' $null
        if ($null -ne $direct) { $directHealthy = [bool]$direct.healthy; $directStatus = [string]$direct.status }
        if ($null -ne $proxy) { $proxyHealthy = [bool]$proxy.healthy; $proxyStatus = [string]$proxy.status }
    }

    $code = 'Unknown'
    $title = '需要进一步检查'
    $messageText = '当前证据不足，断网急救不会自动修改未知配置。'
    $action = '查看诊断报告。'
    $autoRepairAllowed = $false

    if ($staleSystemProxy -and $guardClients.Count -gt 0) {
        $code = 'ProxyGuardConflict'; $title = '客户端正在守护失效代理'; $messageText = '代理端口已经失效，但客户端可能重新写回系统代理。'; $action = '关闭代理守护或完整退出该客户端后再恢复普通网络。'
    }
    elseif ($staleSystemProxy) {
        $code = 'StaleSystemProxy'; $title = '系统代理已经失效'; $messageText = "Windows 仍指向 $systemEndpoint，但该端口无人监听。"; $action = '可自动关闭失效系统代理并恢复普通网络。'; $autoRepairAllowed = $true
    }
    elseif ($activeFlClashClients.Count -gt 1) {
        $code = 'SharedRuntimeConflict'; $title = '多个同源客户端正在互相争用'; $messageText = "检测到多个 FlClash 同源客户端同时运行：$($activeFlClashClients.Name -join '、')。"; $action = '一键退出全部代理并恢复普通网络；确认直连后只打开一个客户端。'
    }
    elseif ($ipcBrokenClients.Count -gt 0) {
        $code = 'ClientIpcBroken'; $title = '客户端内部控制连接已失效'; $messageText = "$($ipcBrokenClients[0].Name) 的核心仍在，但本地控制端口无人监听。"; $action = '一键退出全部代理并恢复普通网络，然后只重新打开一个客户端。'
    }
    elseif ($knownOwnerIds.Count -gt 1) {
        $code = 'MultiOwnerConflict'; $title = '多个代理客户端正在同时接管'; $messageText = '系统代理、TUN、DNS、WinHTTP 或环境变量属于不同客户端。'; $action = '一键退出全部代理并恢复普通网络；确认直连后只打开一个客户端。'
    }
    elseif ($tunResiduals.Count -gt 0) {
        $code = 'TunResidual'; $title = '发现 TUN 残留'; $messageText = '客户端核心已退出，但虚拟网卡或默认路由仍在接管网络。'; $action = '确认归属后使用 Helper 定向清理。'
    }
    elseif ($orphanCoreOwners.Count -gt 0) {
        $portOwner = $orphanCoreOwners[0]
        $code = 'OrphanCore'; $title = '代理界面已退出，但核心仍在运行'; $messageText = "$($portOwner.Client) 的 $($portOwner.Process)（PID $($portOwner.Pid)）仍占用 $($portOwner.Port)。"; $action = '确认后一键退出全部代理并恢复普通网络。'
    }
    elseif ($applicationSplit) {
        $code = 'ApplicationPathSplit'; $title = '浏览器和应用可能走不同代理'; $messageText = 'Windows 系统代理与 Codex、终端使用的环境变量不一致。'; $action = '同步到当前代理，或清除旧环境变量。'
    }
    elseif ($proxyFailureCandidate) {
        $code = 'ProxyPathDegraded'; $title = '代理线路暂时异常'; $messageText = '本地端口正常、普通网络可用，但多个代理探测目标失败。'; $action = '继续观察；持续异常时提示更新节点或恢复普通网络，不自动关闭代理。'
    }
    elseif ($directStatus -eq 'Failed' -and $proxyStatus -in @('Failed','NotTested')) {
        $code = 'LocalNetworkFailure'; $title = '普通网络也不可用'; $messageText = '绕过系统代理后的多个联网探测均失败。'; $action = '检查物理网络、路由器或运营商；不要反复切换代理设置。'
    }
    elseif ($knownOwnerIds.Count -eq 1 -and $null -ne $SystemProxyOwner -and @($TunOwners | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ClientId' -and $_.ClientId -eq $SystemProxyOwner.ClientId
    }).Count -gt 0) {
        $code = 'MixedModeSameOwner'; $title = '同一客户端使用混合接管'; $messageText = "$($SystemProxyOwner.Client) 同时开启了系统代理和 TUN，当前不视为冲突。"; $action = '联网正常时无需处理；发生故障时可考虑只保留一种接管方式。'
    }
    elseif ($knownOwnerIds.Count -eq 0 -and $directHealthy) {
        $code = 'HealthyDirect'; $title = '普通网络正常'; $messageText = '未发现有效代理 Owner。'; $action = '无需操作。'
    }
    elseif ($knownOwnerIds.Count -eq 1 -and ($proxyHealthy -or @($TunOwners).Count -gt 0)) {
        $ownerName = ($Clients | Where-Object { $_.Id -eq $knownOwnerIds[0] } | Select-Object -ExpandProperty Name -First 1)
        $code = 'HealthySingleOwner'; $title = '代理接管正常'; $messageText = "当前主要由 $ownerName 接管网络。"; $action = '无需操作。'
    }

    return [pscustomobject][ordered]@{
        code = $code
        title = $title
        message = $messageText
        recommendedAction = $action
        autoRepairAllowed = $autoRepairAllowed
        ownerIds = @($knownOwnerIds)
        findings = $findings.ToArray()
    }
}

function New-Conflict {
    param([string]$Severity, [string]$Layer, [string]$Summary, [string]$Recommendation)
    return [pscustomobject]@{ Severity = $Severity; Layer = $Layer; Summary = $Summary; Recommendation = $Recommendation }
}

function Get-ConflictSnapshot {
    param($SystemProxy, $SystemProxyOwner, $TunOwners, $DnsOwners, $WinHttp, $WinHttpOwner, $EnvironmentProxies, $EnvironmentOwners, $Clients, $Listeners)
    $conflicts = New-Object System.Collections.Generic.List[object]

    if ($SystemProxy.Enabled -and $null -ne $SystemProxy.Endpoint -and $null -eq $SystemProxyOwner) {
        $conflicts.Add((New-Conflict '紧急' '系统代理' "系统代理指向 $($SystemProxy.Endpoint.Text)，但端口没有已识别监听者。" '关闭失效系统代理，恢复普通网络。'))
    }

    $ownerIds = New-Object System.Collections.Generic.List[string]
    foreach ($owner in @($SystemProxyOwner) + @($TunOwners) + @($DnsOwners) + @($WinHttpOwner) + @($EnvironmentOwners)) {
        if ($null -eq $owner -or $owner.PSObject.Properties.Name -notcontains 'ClientId') { continue }
        if ($owner.ClientId -ne 'unknown' -and -not $ownerIds.Contains([string]$owner.ClientId)) {
            $ownerIds.Add([string]$owner.ClientId)
        }
    }
    if ($ownerIds.Count -gt 1) {
        $names = @($Clients | Where-Object { $ownerIds -contains $_.Id } | Select-Object -ExpandProperty Name)
        $conflicts.Add((New-Conflict '高风险' '多层接管' "检测到多个网络 Owner：$($names -join '、')。" '一键退出全部代理并恢复普通网络；确认直连后只打开一个客户端。'))
    }

    $systemEndpointText = if ($null -ne $SystemProxy.Endpoint) { [string]$SystemProxy.Endpoint.Text } else { '' }
    $splitEnvironment = @($EnvironmentProxies | Where-Object {
        $null -ne $_.Endpoint -and $SystemProxy.Enabled -and $_.Endpoint.Text -ne $systemEndpointText
    })
    $environmentOnlySplit = @($EnvironmentProxies | Where-Object { $null -ne $_.Endpoint }).Count -gt 0 -and
        -not $SystemProxy.Enabled -and @($TunOwners | Where-Object { $null -ne $_ }).Count -eq 0
    $staleEnvironment = @($EnvironmentProxies | Where-Object {
        if ($null -eq $_.Endpoint) { return $false }
        $environmentPort = [int]$_.Endpoint.Port
        return (@($Listeners | Where-Object { $_.Protocol -eq 'TCP' -and $_.Port -eq $environmentPort }).Count -eq 0)
    })
    if ($splitEnvironment.Count -gt 0 -or $staleEnvironment.Count -gt 0 -or $environmentOnlySplit) {
        $conflicts.Add((New-Conflict '高风险' '应用代理路径' 'Codex、终端等应用的代理环境变量与 Windows 当前网络路径不一致或已经失效。' '选择同步到当前代理，或清除旧的本地代理环境变量并重启应用。'))
    }

    if ($null -ne $SystemProxyOwner -and @($TunOwners).Count -gt 0) {
        $differentTun = @($TunOwners | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties.Name -contains 'ClientId' -and
            $_.ClientId -ne 'unknown' -and
            $_.ClientId -ne $SystemProxyOwner.ClientId
        })
        if ($differentTun.Count -gt 0) {
            $conflicts.Add((New-Conflict '高风险' '系统代理/TUN' "系统代理属于 $($SystemProxyOwner.Client)，TUN 属于 $($differentTun[0].Client)。" '不要让不同客户端同时接管系统代理和 TUN。'))
        }
    }

    $runningCoreClients = @($Clients | Where-Object { $_.HasCoreEvidence })
    if ($runningCoreClients.Count -gt 1 -and $ownerIds.Count -le 1) {
        $conflicts.Add((New-Conflict '中风险' '后台核心' "多个客户端保留核心或监听端口：$($runningCoreClients.Name -join '、')。" '确认未使用的客户端已断开并从托盘退出。'))
    }

    $activeFlClashClients = @($Clients | Where-Object {
        (Get-ObjectPropertyValue $_ 'RuntimeFamily' '') -eq 'flclash' -and (@($_.UiProcesses).Count -gt 0 -or @($_.CoreProcesses).Count -gt 0)
    })
    if ($activeFlClashClients.Count -gt 1) {
        $conflicts.Add((New-Conflict '高风险' '同源运行时' "多个 FlClash 同源客户端同时运行：$($activeFlClashClients.Name -join '、')。" '一键退出全部代理并恢复普通网络；确认直连后只打开一个客户端。'))
    }
    foreach ($client in @($Clients | Where-Object { [bool](Get-ObjectPropertyValue $_ 'IpcBroken' $false) })) {
        $conflicts.Add((New-Conflict '高风险' '客户端 IPC' "$($client.Name) 的核心命令行控制端口无人监听。" '清场恢复直连后，仅重新打开一个客户端。'))
    }

    $guardClients = @($Clients | Where-Object { $_.ProxyGuard -eq '已开启' })
    foreach ($client in $guardClients) {
        $conflicts.Add((New-Conflict '中风险' '代理守护' "$($client.Name) 已开启内置代理守护。" '关闭客户端内置代理守护，避免反复覆盖系统代理。'))
    }

    $unknownTun = @($TunOwners | Where-Object {
        $null -ne $_ -and
        $_.PSObject.Properties.Name -contains 'ClientId' -and
        $_.ClientId -eq 'unknown'
    })
    if ($unknownTun.Count -gt 0) {
        $conflicts.Add((New-Conflict '中风险' 'TUN' '检测到无法确认归属的 TUN 默认路由。' '只读保留，不自动删除；先确认网卡和客户端归属。'))
    }

    return [pscustomobject]@{ Conflicts = $conflicts.ToArray(); OwnerIds = $ownerIds.ToArray() }
}

function Convert-OwnerToText {
    param($Owner)
    if ($null -eq $Owner) { return '无' }
    return "$($Owner.Client)（$($Owner.Evidence)）"
}

function ConvertTo-MarkdownReport {
    param($Report)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# 断网急救：网络接管扫描报告')
    $lines.Add('')
    $lines.Add("> 扫描时间：$($Report.scannedAtLocal)  ")
    $lines.Add("> 扫描器版本：$($Report.version)  ")
    $lines.Add('> 模式：只读，不修改任何网络设置')
    $lines.Add('')
    $lines.Add('## 结论')
    $lines.Add('')
    $lines.Add("- 诊断状态：$($Report.diagnosis.code) / $($Report.diagnosis.title)")
    $lines.Add("- 诊断说明：$($Report.diagnosis.message)")
    $lines.Add("- 建议操作：$($Report.diagnosis.recommendedAction)")
    $lines.Add("- 有效 Owner：$($Report.summary.effectiveOwner)")
    $lines.Add("- 系统代理：$($Report.summary.systemProxyStatus)")
    $lines.Add("- TUN Owner：$($Report.summary.tunOwner)")
    $lines.Add("- 冲突数量：$($Report.conflicts.Count)")
    $lines.Add("- 扫描警告：$($Report.warnings.Count)")
    $lines.Add('')
    $lines.Add('## 联网路径健康')
    $lines.Add('')
    if ($null -eq $Report.pathHealth) {
        $lines.Add('本次未执行联网路径探测，或探测组件不可用。')
    }
    else {
        $lines.Add("- 绕过系统代理：$($Report.pathHealth.direct.status)，成功 $($Report.pathHealth.direct.successCount)/$($Report.pathHealth.direct.totalCount)")
        $lines.Add("- 当前本地代理：$($Report.pathHealth.proxy.endpoint)，监听=$(if($Report.pathHealth.proxy.listening){'是'}else{'否'})，联网=$($Report.pathHealth.proxy.status)")
        $lines.Add("- 应用环境变量代理：$(if($Report.pathHealth.environmentProxy.endpoint){$Report.pathHealth.environmentProxy.endpoint}else{'未配置'})，联网=$($Report.pathHealth.environmentProxy.status)")
        $lines.Add("- DNS：$($Report.pathHealth.dns.status)，成功 $($Report.pathHealth.dns.successCount)/$($Report.pathHealth.dns.totalCount)")
        $lines.Add("- 说明：$($Report.pathHealth.direct.meaning)")
    }
    $lines.Add('')
    $lines.Add('## 冲突与建议')
    $lines.Add('')
    if ($Report.conflicts.Count -eq 0) {
        $lines.Add('未发现有明确证据的多客户端接管冲突。')
    }
    else {
        $lines.Add('| 级别 | 接管层 | 发现 | 建议 |')
        $lines.Add('|---|---|---|---|')
        foreach ($item in $Report.conflicts) {
            $lines.Add("| $($item.Severity) | $($item.Layer) | $($item.Summary -replace '\|','/') | $($item.Recommendation -replace '\|','/') |")
        }
    }
    $lines.Add('')
    $lines.Add('## 网络 Owner')
    $lines.Add('')
    $lines.Add('| 接管层 | Owner | 证据 |')
    $lines.Add('|---|---|---|')
    $systemOwner = $Report.owners.systemProxy
    $lines.Add("| Windows 系统代理 | $(if($null -ne $systemOwner){$systemOwner.Client}else{'无'}) | $(if($null -ne $systemOwner){$systemOwner.Evidence}else{'未发现有效本地端口 Owner'}) |")
    if ($Report.owners.tun.Count -eq 0) { $lines.Add('| TUN | 无 | 未发现 TUN 默认路由 |') }
    foreach ($owner in $Report.owners.tun) { $lines.Add("| TUN | $($owner.Client) | $($owner.InterfaceAlias) → $($owner.NextHop) |") }
    if ($Report.owners.dns.Count -eq 0) { $lines.Add('| DNS | 未确认 | 未发现可映射到代理客户端的 DNS 接管证据 |') }
    foreach ($owner in $Report.owners.dns) { $lines.Add("| DNS | $($owner.Client) | $($owner.InterfaceAlias)：$($owner.Evidence) |") }
    $lines.Add("| WinHTTP | $(if($null -ne $Report.owners.winHttp){$Report.owners.winHttp.Client}else{'无或未知'}) | $($Report.winHttp.Raw -replace "`r?`n", '；') |")
    $lines.Add('')
    $lines.Add('## 客户端盘点')
    $lines.Add('')
    $lines.Add('| 客户端 | UI | 核心 | Helper/服务 | 核心端口 | Helper 端口 | 代理守护 |')
    $lines.Add('|---|---:|---:|---:|---|---|---|')
    foreach ($client in $Report.clients) {
        $corePorts = @($client.CoreListeners | Select-Object -ExpandProperty Port -Unique) -join '、'
        $helperPorts = @($client.HelperListeners | Select-Object -ExpandProperty Port -Unique) -join '、'
        if ([string]::IsNullOrWhiteSpace($corePorts)) { $corePorts = '-' }
        if ([string]::IsNullOrWhiteSpace($helperPorts)) { $helperPorts = '-' }
        $lines.Add("| $($client.Name) | $($client.UiProcesses.Count) | $($client.CoreProcesses.Count) | $($client.HelperProcesses.Count + $client.Services.Count) | $corePorts | $helperPorts | $($client.ProxyGuard) |")
    }
    $lines.Add('')
    $lines.Add('## 系统代理与环境代理')
    $lines.Add('')
    $lines.Add("- Windows 系统代理：$(if($Report.systemProxy.Enabled){'开启'}else{'关闭'})；地址：$(if($Report.systemProxy.Server){$Report.systemProxy.Server}else{'无'})")
    $lines.Add("- PAC 自动配置：$(if($Report.systemProxy.AutoConfigUrl){$Report.systemProxy.AutoConfigUrl}else{'未设置'})")
    $lines.Add("- WinHTTP：$($Report.winHttp.Raw -replace "`r?`n", '；')")
    if ($Report.environmentProxies.Count -eq 0) { $lines.Add('- 代理环境变量：未设置') }
    foreach ($item in $Report.environmentProxies) { $lines.Add("- $($item.Scope) / $($item.Name)：$($item.Value)") }
    $lines.Add('')
    $lines.Add('## TUN、路由与 DNS')
    $lines.Add('')
    if ($Report.owners.tun.Count -eq 0) { $lines.Add('- 未发现 TUN 默认路由 Owner。') }
    foreach ($item in $Report.owners.tun) { $lines.Add("- TUN：$($item.Client)，接口 $($item.InterfaceAlias)，下一跳 $($item.NextHop)，Metric $($item.Metric)") }
    foreach ($dns in $Report.network.Dns) { $lines.Add("- DNS：$($dns.InterfaceAlias) / $($dns.AddressFamily) → $(@($dns.ServerAddresses) -join '、')") }
    $lines.Add('')
    $lines.Add('## 扫描警告')
    $lines.Add('')
    if ($Report.warnings.Count -eq 0) { $lines.Add('无。') }
    foreach ($warning in $Report.warnings) { $lines.Add("- $warning") }
    $lines.Add('')
    $lines.Add('## 隐私说明')
    $lines.Add('')
    $lines.Add('报告不会记录订阅 URL、账号、Token、Cookie、Clash 控制密钥、节点密码或完整公网 IP。带认证信息的代理 URI 已脱敏。')
    return ($lines -join "`r`n")
}

function Invoke-ScannerSelfTest {
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($case in @(
        @{ Value = '127.0.0.1:7890'; Port = 7890 },
        @{ Value = 'http=127.0.0.1:7892;https=127.0.0.1:7892'; Port = 7892 },
        @{ Value = 'socks5://localhost:7898'; Port = 7898 }
    )) {
        $result = Get-LocalEndpoint $case.Value
        if ($null -eq $result -or $result.Port -ne $case.Port) { $failures.Add("本地端点解析失败：$($case.Value)") }
    }
    if ($null -ne (Get-LocalEndpoint 'http://proxy.example.com:8080')) { $failures.Add('远程代理被误判为本地端点。') }
    $redacted = ConvertTo-RedactedProxyValue 'http://user:password@127.0.0.1:7890'
    if ($redacted -match 'password|user') { $failures.Add('代理认证信息脱敏失败。') }
    $adapters = Get-Adapters
    $owner = Get-ClientForProcessName -ProcessName 'verge-mihomo' -Adapters $adapters
    if ($null -eq $owner -or $owner.id -ne 'clash_verge') { $failures.Add('Clash Verge 核心映射失败。') }
    $party = $adapters | Where-Object { $_.id -eq 'clash_party' } | Select-Object -First 1
    if ($null -eq $party) { $failures.Add('缺少 Clash Party 适配器。') }
    $bareMihomo = Get-ClientForProcessName -ProcessName 'mihomo' -Adapters $adapters
    if ($null -ne $bareMihomo) { $failures.Add("没有路径证据的通用 mihomo 被误归属为 $($bareMihomo.name)。") }
    $partyOwner = Get-ClientForProcessName -ProcessName 'mihomo' -ProcessPath 'D:\Apps\Clash Party\resources\sidecar\mihomo.exe' -Adapters $adapters
    if ($null -eq $partyOwner -or $partyOwner.id -ne 'clash_party') { $failures.Add('Clash Party 的 mihomo 路径映射失败。') }
    $partyFixtureProcesses = @(
        [pscustomobject]@{ Id=201; Name='Clash Party'; Path='D:\Apps\Clash Party\Clash Party.exe'; CommandLine=''; StartTimeUtc='2026-07-16T00:00:00Z'; SessionId=1 },
        [pscustomobject]@{ Id=202; Name='mihomo'; Path='D:\Apps\Clash Party\resources\sidecar\mihomo.exe'; CommandLine=''; StartTimeUtc='2026-07-16T00:00:01Z'; SessionId=1 },
        [pscustomobject]@{ Id=203; Name='mihomo'; Path='D:\Apps\Other Client\mihomo.exe'; CommandLine=''; StartTimeUtc='2026-07-16T00:00:02Z'; SessionId=1 }
    )
    $partyFixtureClients = Get-ClientSnapshot -Adapters $adapters -Processes $partyFixtureProcesses -Services @() -Listeners @()
    $partyFixture = $partyFixtureClients | Where-Object { $_.Id -eq 'clash_party' } | Select-Object -First 1
    $vergeFixture = $partyFixtureClients | Where-Object { $_.Id -eq 'clash_verge' } | Select-Object -First 1
    if (@($partyFixture.UiProcesses).Count -ne 1 -or @($partyFixture.CoreProcesses).Count -ne 1) { $failures.Add('Clash Party UI/Core 路径归属测试失败。') }
    if (@($vergeFixture.CoreProcesses).Count -ne 0) { $failures.Add('Clash Party 的 mihomo 仍被 Clash Verge 适配器抢先匹配。') }
    foreach ($adapter in $adapters) {
        if ($adapter.PSObject.Properties.Name -notcontains 'defaultProxyPorts' -or @($adapter.defaultProxyPorts).Count -eq 0) { $failures.Add("$($adapter.name) 缺少默认代理端口。") }
        if ($adapter.PSObject.Properties.Name -notcontains 'proxyCapabilities' -or @($adapter.proxyCapabilities).Count -eq 0) { $failures.Add("$($adapter.name) 缺少代理协议能力。") }
        if ($adapter.PSObject.Properties.Name -notcontains 'safeStopProcessPatterns' -or @($adapter.safeStopProcessPatterns).Count -eq 0) { $failures.Add("$($adapter.name) 缺少安全停止进程白名单。") }
        if ($adapter.PSObject.Properties.Name -notcontains 'runtimeFamily' -or [string]::IsNullOrWhiteSpace([string]$adapter.runtimeFamily)) { $failures.Add("$($adapter.name) 缺少运行时家族。") }
        if ($adapter.PSObject.Properties.Name -notcontains 'sharedControlPorts') { $failures.Add("$($adapter.name) 缺少共享控制端口字段。") }
        if ($adapter.PSObject.Properties.Name -notcontains 'controlPortFromCoreArgs') { $failures.Add("$($adapter.name) 缺少动态控制端口识别开关。") }
    }
    if ((Get-ControlPortFromCommandLine '"C:\Program Files\lmclientCore.exe" -d C:\Temp 12460') -ne 12460) { $failures.Add('核心命令行动态控制端口提取失败。') }
    if ($null -ne (Get-ControlPortFromCommandLine '"C:\Program Files\lmclientCore.exe" -d C:\Temp')) { $failures.Add('无端口核心命令行被误识别。') }
    $duplicateListenerClient = [pscustomobject]@{
        Id='longmao'; Name='龙猫云 Lite'; UiProcesses=@([pscustomobject]@{Id=10});
        CoreProcesses=@([pscustomobject]@{Id=20;StartTimeUtc='2026-07-14T00:00:00Z';SessionId=1});
        CoreListeners=@(
            [pscustomobject]@{Protocol='TCP';Address='127.0.0.1';Port=7890;Pid=20;Process='lmclientCore'},
            [pscustomobject]@{Protocol='UDP';Address='127.0.0.1';Port=7890;Pid=20;Process='lmclientCore'}
        );
        DefaultProxyPorts=@(7890)
    }
    $deduplicatedPorts = @(Get-PortOwnerSnapshot -Clients @($duplicateListenerClient))
    if ($deduplicatedPorts.Count -ne 1) { $failures.Add('同一核心的 IPv4/IPv6 监听被重复列为端口 Owner。') }

    $endpoint7890 = [pscustomobject]@{ Text='127.0.0.1:7890'; Port=7890 }
    $endpoint7892 = [pscustomobject]@{ Text='127.0.0.1:7892'; Port=7892 }
    $systemProxy = [pscustomobject]@{ Enabled=$true; Endpoint=$endpoint7890 }
    $systemOwner = [pscustomobject]@{ ClientId='clash_verge'; Client='Clash Verge'; Evidence='测试' }
    $tunSame = [pscustomobject]@{ ClientId='clash_verge'; Client='Clash Verge'; InterfaceAlias='测试TUN'; NextHop='198.18.0.1' }
    $tunOther = [pscustomobject]@{ ClientId='longmao'; Client='龙猫云 Lite'; InterfaceAlias='测试TUN'; NextHop='198.18.0.1' }
    $clientA = [pscustomobject]@{ Id='clash_verge'; Name='Clash Verge'; ProxyGuard='未发现开启证据'; HasCoreEvidence=$true; UiProcesses=@([pscustomobject]@{Id=1}); DefaultProxyPorts=@(7890); CoreListeners=@(); CoreProcesses=@() }
    $clientB = [pscustomobject]@{ Id='longmao'; Name='龙猫云 Lite'; ProxyGuard='未发现开启证据'; HasCoreEvidence=$true; UiProcesses=@([pscustomobject]@{Id=2}); DefaultProxyPorts=@(7892); CoreListeners=@(); CoreProcesses=@() }
    $winHttp = [pscustomobject]@{ Endpoint=$null }
    $healthyPath = [pscustomobject]@{ proxyFailureCandidate=$false; direct=[pscustomobject]@{healthy=$true;status='Healthy'}; proxy=[pscustomobject]@{healthy=$true;status='Healthy'} }
    $mixed = Get-DiagnosisSnapshot -SystemProxy $systemProxy -SystemProxyOwner $systemOwner -TunOwners @($tunSame) -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($clientA) -Listeners @() -PortOwners @() -OwnerIds @('clash_verge') -PathHealth $healthyPath
    if ($mixed.code -ne 'MixedModeSameOwner') { $failures.Add("同客户端系统代理和 TUN 被错误分类为：$($mixed.code)") }
    $multi = Get-DiagnosisSnapshot -SystemProxy $systemProxy -SystemProxyOwner $systemOwner -TunOwners @($tunOther) -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($clientA,$clientB) -Listeners @() -PortOwners @() -OwnerIds @('clash_verge','longmao') -PathHealth $healthyPath
    if ($multi.code -ne 'MultiOwnerConflict') { $failures.Add("不同客户端多 Owner 被错误分类为：$($multi.code)") }
    $stale = Get-DiagnosisSnapshot -SystemProxy $systemProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($clientA) -Listeners @() -PortOwners @() -OwnerIds @() -PathHealth $healthyPath
    if ($stale.code -ne 'StaleSystemProxy' -or -not $stale.autoRepairAllowed) { $failures.Add('失效系统代理分类或自动修复边界错误。') }
    $environmentItem = [pscustomobject]@{ Scope='User'; Name='HTTP_PROXY'; Endpoint=$endpoint7892 }
    $split = Get-DiagnosisSnapshot -SystemProxy $systemProxy -SystemProxyOwner $systemOwner -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @($environmentItem) -EnvironmentOwners @() -Clients @($clientA) -Listeners @() -PortOwners @() -OwnerIds @('clash_verge') -PathHealth $healthyPath
    if ($split.code -ne 'ApplicationPathSplit') { $failures.Add("应用路径分裂被错误分类为：$($split.code)") }
    $applicationOnlyListener = [pscustomobject]@{ Protocol='TCP'; Port=7892; Address='127.0.0.1' }
    $applicationOnly = Get-DiagnosisSnapshot -SystemProxy ([pscustomobject]@{ Enabled=$false; Endpoint=$null }) -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @($environmentItem) -EnvironmentOwners @([pscustomobject]@{ClientId='longmao'}) -Clients @($clientB) -Listeners @($applicationOnlyListener) -PortOwners @() -OwnerIds @('longmao') -PathHealth $healthyPath
    if ($applicationOnly.code -ne 'ApplicationPathSplit') { $failures.Add("Windows 代理关闭但应用仍走代理时被错误分类为：$($applicationOnly.code)") }
    $failedPath = [pscustomobject]@{ proxyFailureCandidate=$true; direct=[pscustomobject]@{healthy=$true;status='Healthy'}; proxy=[pscustomobject]@{healthy=$false;status='Failed'} }
    $degraded = Get-DiagnosisSnapshot -SystemProxy $systemProxy -SystemProxyOwner $systemOwner -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($clientA) -Listeners @() -PortOwners @() -OwnerIds @('clash_verge') -PathHealth $failedPath
    if ($degraded.code -ne 'ProxyPathDegraded') { $failures.Add("线路失效候选被错误分类为：$($degraded.code)") }
    $disabledProxy = [pscustomobject]@{ Enabled=$false; Endpoint=$null }
    $clientWithoutUi = $clientA.PSObject.Copy(); $clientWithoutUi.UiProcesses = @()
    $backgroundPort = [pscustomobject]@{ ClientId='clash_verge'; Client='Clash Verge'; Port=7890; Pid=1234; Process='verge-mihomo'; UiRunning=$false; DeclaredPort=$true }
    $occupied = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($clientWithoutUi) -Listeners @() -PortOwners @($backgroundPort) -OwnerIds @() -PathHealth $healthyPath
    if ($occupied.code -ne 'OrphanCore') { $failures.Add("后台核心端口残留被错误分类为：$($occupied.code)") }
    $flA = [pscustomobject]@{ Id='longmao'; Name='龙猫云 Lite'; RuntimeFamily='flclash'; IpcBroken=$false; ProxyGuard='未发现开启证据'; HasCoreEvidence=$true; UiProcesses=@([pscustomobject]@{Id=1}); CoreProcesses=@([pscustomobject]@{Id=11}); DefaultProxyPorts=@(7890); CoreListeners=@(); ControlPorts=@() }
    $flB = [pscustomobject]@{ Id='v2cloud'; Name='V2Cloud'; RuntimeFamily='flclash'; IpcBroken=$false; ProxyGuard='未发现开启证据'; HasCoreEvidence=$true; UiProcesses=@([pscustomobject]@{Id=2}); CoreProcesses=@([pscustomobject]@{Id=12}); DefaultProxyPorts=@(7890); CoreListeners=@(); ControlPorts=@() }
    $shared = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($flA,$flB) -Listeners @() -PortOwners @() -OwnerIds @() -PathHealth $healthyPath
    if ($shared.code -ne 'SharedRuntimeConflict') { $failures.Add("FlClash 同源冲突被错误分类为：$($shared.code)") }
    $ipcClient = [pscustomobject]@{ Id='longmao'; Name='龙猫云 Lite'; RuntimeFamily='flclash'; IpcBroken=$true; ProxyGuard='未发现开启证据'; HasCoreEvidence=$true; UiProcesses=@([pscustomobject]@{Id=1}); CoreProcesses=@([pscustomobject]@{Id=11}); DefaultProxyPorts=@(7890); CoreListeners=@(); ControlPorts=@(12460) }
    $ipc = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients @($ipcClient) -Listeners @() -PortOwners @() -OwnerIds @() -PathHealth $healthyPath
    if ($ipc.code -ne 'ClientIpcBroken') { $failures.Add("客户端 IPC 失效被错误分类为：$($ipc.code)") }
    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) { Write-Host "失败：$failure" -ForegroundColor Red }
        throw "自检失败，共 $($failures.Count) 项。"
    }
    Write-Host '扫描器自检通过：端点解析、脱敏、适配器字段和诊断状态分类正常。' -ForegroundColor Green
}

function Invoke-NetworkOwnershipScan {
    $adapters = Get-Adapters
    $processes = Get-ProcessSnapshot
    $services = Get-ServiceSnapshot
    $tcpListeners = Get-TcpListeners -Processes $processes
    $udpListeners = Get-UdpListeners -Processes $processes
    $allListeners = @($tcpListeners) + @($udpListeners)
    $systemProxy = Get-SystemProxySnapshot
    $winHttp = Get-WinHttpSnapshot
    $environmentProxies = Get-EnvironmentProxySnapshot
    $network = Get-NetworkSnapshot
    $clients = Get-ClientSnapshot -Adapters $adapters -Processes $processes -Services $services -Listeners $allListeners

    $systemProxyOwner = if ($systemProxy.Enabled) {
        Resolve-ListenerOwner -Endpoint $systemProxy.Endpoint -Listeners $tcpListeners -Adapters $adapters -Processes $processes
    }
    else { $null }
    $tunOwners = Get-TunOwners -Network $network -Adapters $adapters -Clients $clients
    $dnsOwners = Get-DnsOwnerCandidates -Network $network -TunOwners $tunOwners -UdpListeners $udpListeners -Adapters $adapters -Processes $processes
    $winHttpOwner = Resolve-ListenerOwner -Endpoint $winHttp.Endpoint -Listeners $tcpListeners -Adapters $adapters -Processes $processes
    $environmentOwners = @()
    foreach ($item in $environmentProxies) {
        if ($null -eq $item.Endpoint) { continue }
        $owner = Resolve-ListenerOwner -Endpoint $item.Endpoint -Listeners $tcpListeners -Adapters $adapters -Processes $processes
        if ($null -ne $owner) { $environmentOwners += $owner }
    }

    $conflictResult = Get-ConflictSnapshot -SystemProxy $systemProxy -SystemProxyOwner $systemProxyOwner `
        -TunOwners $tunOwners -DnsOwners $dnsOwners -WinHttp $winHttp -WinHttpOwner $winHttpOwner `
        -EnvironmentProxies $environmentProxies -EnvironmentOwners $environmentOwners -Clients $clients -Listeners $tcpListeners

    $portOwners = Get-PortOwnerSnapshot -Clients $clients
    $pathHealth = $null
    if (-not $SkipPathHealth) {
        if (-not (Test-Path -LiteralPath $PathHealthScript)) {
            Add-ScanWarning "联网路径探测脚本不存在：$PathHealthScript"
        }
        else {
            try {
                $environmentProbe = $environmentProxies | Where-Object {
                    $_.Name -in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY') -and $null -ne $_.Endpoint
                } | Select-Object -First 1
                $proxyEndpointText = if ($systemProxy.Enabled -and $null -ne $systemProxy.Endpoint) { [string]$systemProxy.Endpoint.Text } else { '' }
                $environmentEndpointText = if ($null -ne $environmentProbe) { [string]$environmentProbe.Endpoint.Text } else { '' }
                $pathOutput = & $PathHealthScript -ProxyEndpoint $proxyEndpointText -EnvironmentProxyEndpoint $environmentEndpointText -TimeoutSeconds $ProbeTimeoutSeconds -PassThru
                $pathHealth = @($pathOutput | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'schemaVersion' }) | Select-Object -Last 1
            }
            catch { Add-ScanWarning "联网路径探测失败：$($_.Exception.Message)" }
        }
    }

    $diagnosis = Get-DiagnosisSnapshot -SystemProxy $systemProxy -SystemProxyOwner $systemProxyOwner `
        -TunOwners $tunOwners -WinHttp $winHttp -WinHttpOwner $winHttpOwner -EnvironmentProxies $environmentProxies `
        -EnvironmentOwners $environmentOwners -Clients $clients -Listeners $tcpListeners -PortOwners $portOwners `
        -OwnerIds $conflictResult.OwnerIds -PathHealth $pathHealth

    $networkOwnerIds = New-Object System.Collections.Generic.List[string]
    foreach ($owner in @($systemProxyOwner) + @($tunOwners) + @($dnsOwners) + @($winHttpOwner)) {
        if ($null -eq $owner -or $owner.PSObject.Properties.Name -notcontains 'ClientId' -or $owner.ClientId -eq 'unknown') { continue }
        if (-not $networkOwnerIds.Contains([string]$owner.ClientId)) { $networkOwnerIds.Add([string]$owner.ClientId) }
    }
    $networkOwnerNames = @($clients | Where-Object { $networkOwnerIds -contains $_.Id } | Select-Object -ExpandProperty Name)
    $applicationOwnerNames = @($clients | Where-Object {
        $clientId = $_.Id
        @($environmentOwners | Where-Object { $_.ClientId -eq $clientId }).Count -gt 0
    } | Select-Object -ExpandProperty Name -Unique)
    $effectiveOwner = if ($networkOwnerNames.Count -eq 0 -and $applicationOwnerNames.Count -gt 0) {
        "Windows 未由代理接管；仅部分应用使用 $($applicationOwnerNames -join '、')"
    }
    elseif ($networkOwnerNames.Count -eq 0) { '未发现有效代理 Owner，可能为普通直连' }
    elseif ($networkOwnerNames.Count -eq 1) { $networkOwnerNames[0] }
    else { "多 Owner 冲突：$($networkOwnerNames -join '、')" }
    $systemProxyStatus = if (-not $systemProxy.Readable) { '未能读取' } elseif (-not $systemProxy.Enabled) { '关闭' } elseif ($null -ne $systemProxyOwner) { "开启，Owner=$($systemProxyOwner.Client)" } else { '开启，但未找到有效本地 Owner' }
    $validTunOwners = @($tunOwners | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'Client' })
    $tunOwnerText = if ($validTunOwners.Count -eq 0) { '无' } else { (@($validTunOwners | Select-Object -ExpandProperty Client -Unique) -join '、') }

    return [pscustomobject][ordered]@{
        schemaVersion = 2
        version = $Script:Version
        scannedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        scannedAtLocal = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        mode = 'read-only'
        summary = [pscustomobject]@{
            effectiveOwner = $effectiveOwner
            systemProxyStatus = $systemProxyStatus
            tunOwner = $tunOwnerText
            diagnosisCode = [string]$diagnosis.code
            diagnosisText = [string]$diagnosis.message
        }
        owners = [pscustomobject]@{
            systemProxy = $systemProxyOwner
            tun = @($validTunOwners)
            dns = @($dnsOwners)
            winHttp = $winHttpOwner
            environment = @($environmentOwners)
        }
        conflicts = @($conflictResult.Conflicts)
        diagnosis = $diagnosis
        pathHealth = $pathHealth
        portOwners = @($portOwners)
        systemProxy = $systemProxy
        winHttp = $winHttp
        environmentProxies = @($environmentProxies)
        clients = @($clients)
        listeners = @($allListeners | Where-Object {
            $listenerRow = $_
            if ($listenerRow.Port -in @(53, 7890, 7891, 7892, 7893, 7897, 7898, 7899, 9090, 9097)) { return $true }
            $processRow = $processes | Where-Object { $_.Id -eq [int]$listenerRow.Pid } | Select-Object -First 1
            return ($null -ne (Get-ClientForProcess -Process $processRow -Adapters $adapters))
        })
        network = $network
        networkSnapshot = [pscustomobject][ordered]@{
            systemProxy = $systemProxy
            winHttp = $winHttp
            environmentProxies = @($environmentProxies)
            owners = [pscustomobject]@{
                systemProxy = $systemProxyOwner
                tun = @($validTunOwners)
                dns = @($dnsOwners)
                winHttp = $winHttpOwner
                environment = @($environmentOwners)
                ports = @($portOwners)
            }
            clients = @($clients)
            listeners = @($allListeners)
            network = $network
        }
        warnings = $Script:Warnings.ToArray()
    }
}

if ($SelfTest) {
    Invoke-ScannerSelfTest
    return
}

$report = Invoke-NetworkOwnershipScan
if (-not $NoWriteReport) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $OutputDirectory "network-ownership-$stamp.json"
    $markdownPath = Join-Path $OutputDirectory "network-ownership-$stamp.md"
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownReport -Report $report | Set-Content -LiteralPath $markdownPath -Encoding UTF8
}

if (-not $Quiet) {
    Write-Host '只读扫描完成。' -ForegroundColor Green
    Write-Host "有效 Owner：$($report.summary.effectiveOwner)"
    Write-Host "冲突数量：$($report.conflicts.Count)"
    if (-not $NoWriteReport) {
        Write-Host "Markdown 报告：$markdownPath"
        Write-Host "JSON 报告：$jsonPath"
    }
}

if ($PassThru) { return $report }
