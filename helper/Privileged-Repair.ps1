[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('StopServices', 'StartServices', 'KillProcesses', 'CleanupTun', 'ResetDns', 'RestoreMachineDirect')]
    [string]$Mode,
    [string]$ClientIds = '',
    [string]$AdapterPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($AdapterPath)) { $AdapterPath = Join-Path $PSScriptRoot 'client_adapters.json' }
if (-not (Test-Path -LiteralPath $AdapterPath)) { throw "未找到适配器文件：$AdapterPath" }
$adapters = @(Get-Content -LiteralPath $AdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$allowedIds = @($adapters | Select-Object -ExpandProperty id)
$requestedIds = @($ClientIds -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
foreach ($id in $requestedIds) { if ($allowedIds -notcontains $id) { throw "未授权的客户端 ID：$id" } }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $identity.Name -ne 'NT AUTHORITY\SYSTEM') {
    throw '高权限修复脚本只能由断网急救 Helper 或管理员运行。'
}
$targets = if ($requestedIds.Count -gt 0) { @($adapters | Where-Object { $requestedIds -contains $_.id }) } else { $adapters }
$actions = New-Object System.Collections.Generic.List[object]

function Add-Action {
    param([string]$Action, [string]$Target, [string]$Result, [bool]$Success = $true)
    $actions.Add([pscustomobject][ordered]@{ action=$Action; target=$Target; result=$Result; success=$Success })
}

function Test-PatternList {
    param([string]$Text, $Patterns)
    foreach ($pattern in @($Patterns)) { if ($Text -match [string]$pattern) { return $true } }
    return $false
}

function Stop-KnownServices {
    foreach ($adapter in $targets) {
        foreach ($service in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { Test-PatternList $_.Name $adapter.servicePatterns })) {
            try {
                if ($service.Status -ne 'Stopped') { Stop-Service -Name $service.Name -Force -ErrorAction Stop; $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15)) }
                Add-Action '停止服务' $service.Name '成功'
            }
            catch { Add-Action '停止服务' $service.Name $_.Exception.Message $false }
        }
    }
}

function Start-KnownServices {
    foreach ($adapter in $targets) {
        foreach ($service in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { Test-PatternList $_.Name $adapter.servicePatterns })) {
            try {
                if ($service.Status -ne 'Running') { Start-Service -Name $service.Name -ErrorAction Stop; $service.WaitForStatus('Running',[TimeSpan]::FromSeconds(15)) }
                Add-Action '启动服务' $service.Name '成功'
            }
            catch { Add-Action '启动服务' $service.Name $_.Exception.Message $false }
        }
    }
}

function Stop-KnownProcesses {
    $currentPid = $PID
    foreach ($adapter in $targets) {
        $safeProperty = $adapter.PSObject.Properties['safeStopProcessPatterns']
        $patterns = if ($null -ne $safeProperty) {
            @($safeProperty.Value)
        }
        else {
            @($adapter.uiProcessPatterns) + @($adapter.coreProcessPatterns)
        }
        $safePathProperty = $adapter.PSObject.Properties['safeStopPathPatterns']
        $safePathPatterns = if ($null -ne $safePathProperty) { @($safePathProperty.Value) } else { @() }
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($process.Id -eq $currentPid -or -not (Test-PatternList $process.ProcessName $patterns)) { continue }
            try {
                $pidToStop = [int]$process.Id
                $nameToStop = [string]$process.ProcessName
                $pathToStop = try { [string]$process.Path } catch { '' }
                if ($safePathPatterns.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($pathToStop) -or -not (Test-PatternList $pathToStop $safePathPatterns))) { continue }
                $startTime = try { $process.StartTime.ToUniversalTime().ToString('o') } catch { '' }
                $current = Get-Process -Id $pidToStop -ErrorAction Stop
                if ($current.ProcessName -ne $nameToStop) { throw '进程 PID 已被其他程序复用，拒绝结束。' }
                $currentPath = try { [string]$current.Path } catch { '' }
                if ($safePathPatterns.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($currentPath) -or -not (Test-PatternList $currentPath $safePathPatterns))) { throw '进程路径不属于目标客户端，拒绝结束。' }
                if ($pathToStop -and $currentPath -and -not [string]::Equals($pathToStop, $currentPath, [StringComparison]::OrdinalIgnoreCase)) { throw '进程路径已经变化，拒绝结束。' }
                $currentStart = try { $current.StartTime.ToUniversalTime().ToString('o') } catch { '' }
                if ($startTime -and $currentStart -and $startTime -ne $currentStart) { throw '进程启动时间已经变化，拒绝结束。' }
                if (-not (Test-PatternList $current.ProcessName $patterns)) { throw '进程已不再匹配客户端白名单。' }
                Stop-Process -Id $pidToStop -Force -ErrorAction Stop
                Add-Action '终止进程' "$nameToStop/$pidToStop" '成功（已复核 PID、名称、路径和启动时间）'
            }
            catch { Add-Action '终止进程' "$($process.ProcessName)/$($process.Id)" $_.Exception.Message $false }
        }
    }
}

function Cleanup-KnownTun {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -like '198.18.*' -or $_.DestinationPrefix -like '198.18.*' })
    foreach ($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)) {
        $text = "$($adapter.Name) $($adapter.InterfaceDescription)"
        $matchesClient = $false
        foreach ($target in $targets) { if (Test-PatternList $text $target.tunInterfacePatterns) { $matchesClient = $true; break } }
        if (-not $matchesClient) { continue }
        $targetRoutes = @($routes | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex })
        foreach ($route in $targetRoutes) {
            try { Remove-NetRoute -InterfaceIndex $route.InterfaceIndex -DestinationPrefix $route.DestinationPrefix -NextHop $route.NextHop -Confirm:$false -ErrorAction Stop; Add-Action '删除 TUN 默认路由' "$($adapter.Name)/$($route.NextHop)" '成功' }
            catch { Add-Action '删除 TUN 默认路由' "$($adapter.Name)/$($route.NextHop)" $_.Exception.Message $false }
        }
        try { Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; Add-Action '清理 TUN DNS' $adapter.Name '成功' }
        catch { Add-Action '清理 TUN DNS' $adapter.Name $_.Exception.Message $false }
        try { Disable-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -Confirm:$false -ErrorAction Stop; Add-Action '禁用 TUN 网卡' $adapter.Name '成功' }
        catch { Add-Action '禁用 TUN 网卡' $adapter.Name $_.Exception.Message $false }
    }
}

function Reset-PhysicalDns {
    $excluded = '(?i)(tun|tap|wintun|wireguard|mihomo|clash|flclash|fcclient|lmclient|globalcloud|abysswalker|qingyun|speedcat|v2cloud|wsl|hyper-v|virtual|loopback|bluetooth|docker|vmware|vbox)'
    foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $text = "$($adapter.Name) $($adapter.InterfaceDescription)"
        if ($text -match $excluded) { continue }
        try { Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; Add-Action '重置物理网卡 DNS' $adapter.Name '成功' }
        catch { Add-Action '重置物理网卡 DNS' $adapter.Name $_.Exception.Message $false }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Restore-MachineDirect {
    $raw = ((& netsh.exe winhttp show proxy 2>&1) -join "`n")
    if ($raw -match '(?i)(127\.0\.0\.1|localhost|\[?::1\]?)') {
        & netsh.exe winhttp reset proxy | Out-Null
        Add-Action '重置 WinHTTP' '本机' '成功'
    }
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name,'Machine')
        if ($value -match '(?i)(127\.0\.0\.1|localhost|\[?::1\]?)') { [Environment]::SetEnvironmentVariable($name,$null,'Machine'); Add-Action '清理机器代理环境变量' $name '成功' }
    }
}

switch ($Mode) {
    'StopServices' { Stop-KnownServices }
    'StartServices' { Start-KnownServices }
    'KillProcesses' { Stop-KnownProcesses }
    'CleanupTun' { Cleanup-KnownTun }
    'ResetDns' { Reset-PhysicalDns }
    'RestoreMachineDirect' { Restore-MachineDirect }
}

$actionArray = @($actions | ForEach-Object { $_ })
$failed = @($actionArray | Where-Object { -not $_.success })
[pscustomobject][ordered]@{ mode=$Mode; clientIds=@($targets.id); success=($failed.Count -eq 0); actions=$actionArray } | ConvertTo-Json -Depth 8 -Compress
if ($failed.Count -gt 0) { exit 2 }
