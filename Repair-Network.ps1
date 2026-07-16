[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Status', 'BackupOnly', 'RestoreDirect', 'EmergencyDirect', 'StopServices', 'StopOtherClients', 'StopSelectedClients', 'StopAllClients', 'PrepareSwitch', 'ResetDns', 'SyncApplicationProxy', 'ClearApplicationProxy', 'RestoreBackup', 'SelfTest')]
    [string]$Mode = 'Status',
    [string]$KeepClient = '',
    [string[]]$TargetClientIds = @(),
    [string]$AdapterPath = '',
    [string]$ScannerPath = '',
    [string]$BackupDirectory = '',
    [string]$BackupPath = '',
    [string]$HelperClientPath = '',
    [string]$ProxyEndpoint = '',
    [ValidateSet('auto', 'http', 'mixed')]
    [string]$ProxyProtocol = 'auto',
    [switch]$AutoElevate,
    [switch]$DisableHelper,
    [switch]$Force,
    [switch]$SkipTunCleanup,
    [switch]$KeepProxyEnvironment,
    [switch]$UserConfirmed
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Version = '0.4.0-beta'
$Script:Actions = New-Object System.Collections.Generic.List[object]
$Script:CurrentBackupPath = ''
$Script:HelperAvailable = $false
$Script:DeferHelper = $false
$Script:ResultPath = Join-Path $PSScriptRoot 'monitor_data\last-repair-result.json'

if ($Force) { $ConfirmPreference = 'None' }

if ([string]::IsNullOrWhiteSpace($AdapterPath)) { $AdapterPath = Join-Path $PSScriptRoot 'client_adapters.json' }
if ([string]::IsNullOrWhiteSpace($ScannerPath)) { $ScannerPath = Join-Path $PSScriptRoot 'Scan-NetworkOwnership.ps1' }
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { $BackupDirectory = Join-Path $PSScriptRoot 'backups' }
if ([string]::IsNullOrWhiteSpace($HelperClientPath)) { $HelperClientPath = Join-Path $PSScriptRoot 'Invoke-NetworkRescueHelper.ps1' }
$Script:ActionLogPath = Join-Path $PSScriptRoot 'repair-actions.log'
$Script:PathHealthScript = Join-Path $PSScriptRoot 'Test-NetworkPathHealth.ps1'
$Script:ActionLogMaxBytes = 2MB
$Script:ActionLogArchiveCount = 3

function Invoke-FileRotation {
    param(
        [string]$Path,
        [long]$MaxBytes,
        [int]$ArchiveCount,
        [long]$IncomingBytes = 0
    )
    if ($MaxBytes -le 0 -or $ArchiveCount -lt 1 -or -not (Test-Path -LiteralPath $Path)) { return }
    if (((Get-Item -LiteralPath $Path -ErrorAction Stop).Length + $IncomingBytes) -le $MaxBytes) { return }
    $oldest = "$Path.$ArchiveCount"
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force -ErrorAction Stop -WhatIf:$false }
    for ($index = $ArchiveCount - 1; $index -ge 1; $index--) {
        $source = "$Path.$index"
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination "$Path.$($index + 1)" -Force -ErrorAction Stop -WhatIf:$false
        }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop -WhatIf:$false
}

function Write-ActionLog {
    param([string]$Level, [string]$Action, [string]$Target, [string]$Result)
    $record = [pscustomobject][ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        action = $Action
        target = $Target
        result = $Result
    }
    $Script:Actions.Add($record)
    $line = '{0} [{1}] {2} | {3} | {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Action, $Target, $Result
    $incomingBytes = [Text.Encoding]::UTF8.GetByteCount($line + [Environment]::NewLine)
    Invoke-FileRotation -Path $Script:ActionLogPath -MaxBytes $Script:ActionLogMaxBytes -ArchiveCount $Script:ActionLogArchiveCount -IncomingBytes $incomingBytes
    Add-Content -LiteralPath $Script:ActionLogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Write-RepairResult {
    param(
        [string]$Status,
        [bool]$SystemProxyClosed,
        [bool]$ResidueCleaned,
        [bool]$DirectConfirmed,
        $Verification = $null,
        [string]$Message = ''
    )
    $directory = Split-Path -Parent $Script:ResultPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [pscustomobject][ordered]@{
        schemaVersion = 1
        version = $Script:Version
        mode = $Mode
        completedAt = (Get-Date).ToString('o')
        status = $Status
        systemProxyClosed = $SystemProxyClosed
        proxyResidueCleaned = $ResidueCleaned
        directConfirmed = $DirectConfirmed
        message = $Message
        backupPath = $Script:CurrentBackupPath
        verification = $Verification
        failedActions = @($Script:Actions | Where-Object { $_.level -eq 'ERROR' })
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Script:ResultPath -Encoding UTF8
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ModeNeedsAdministrator {
    return $Mode -in @('StopServices', 'StopSelectedClients', 'ResetDns', 'RestoreBackup')
}

function Test-ModeCanUseHelper {
    return $Mode -in @('RestoreDirect', 'EmergencyDirect', 'StopServices', 'StopSelectedClients', 'StopAllClients', 'ResetDns')
}

function Test-HelperAvailable {
    if ($DisableHelper -or -not (Test-Path -LiteralPath $HelperClientPath)) { return $false }
    try {
        $ping = & $HelperClientPath -Mode Ping -TimeoutMilliseconds 1500 -PassThru
        return ($null -ne $ping -and [bool]$ping.success)
    }
    catch { return $false }
}

function Invoke-HelperOperation {
    param([string]$Operation, $TargetAdapters = @())
    $ids = @($TargetAdapters | Select-Object -ExpandProperty id -Unique)
    try {
        $result = & $HelperClientPath -Mode $Operation -ClientIds $ids -TimeoutMilliseconds 125000 -PassThru
        if ($null -eq $result -or -not $result.success) {
            $detail = if ($null -ne $result) { [string]$result.output } else { 'Helper 没有返回结果' }
            Write-ActionLog 'ERROR' '高权限 Helper' "$Operation/$($ids -join ',')" $detail
            return $false
        }
        Write-ActionLog 'ACTION' '高权限 Helper' "$Operation/$($ids -join ',')" '成功'
        return $true
    }
    catch {
        Write-ActionLog 'ERROR' '高权限 Helper' "$Operation/$($ids -join ',')" $_.Exception.Message
        return $false
    }
}

function Start-ElevatedSelf {
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add("`"$PSCommandPath`"")
    $arguments.Add('-Mode')
    $arguments.Add($Mode)
    if (-not [string]::IsNullOrWhiteSpace($KeepClient)) { $arguments.Add('-KeepClient'); $arguments.Add("`"$KeepClient`"") }
    if (@($TargetClientIds).Count -gt 0) { $arguments.Add('-TargetClientIds'); $arguments.Add("`"$($TargetClientIds -join ',')`"") }
    if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $arguments.Add('-BackupPath'); $arguments.Add("`"$BackupPath`"") }
    if ($SkipTunCleanup) { $arguments.Add('-SkipTunCleanup') }
    if ($KeepProxyEnvironment) { $arguments.Add('-KeepProxyEnvironment') }
    if ($UserConfirmed) { $arguments.Add('-UserConfirmed') }
    if (-not [string]::IsNullOrWhiteSpace($ProxyEndpoint)) { $arguments.Add('-ProxyEndpoint'); $arguments.Add("`"$ProxyEndpoint`"") }
    if ($ProxyProtocol -ne 'auto') { $arguments.Add('-ProxyProtocol'); $arguments.Add($ProxyProtocol) }
    if ($Force) { $arguments.Add('-Force') }
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($arguments -join ' ') -Wait -PassThru
    exit $process.ExitCode
}

function Get-Adapters {
    return @(Get-Content -LiteralPath $AdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-PatternList {
    param([string]$Text, $Patterns)
    foreach ($pattern in @($Patterns)) { if ($Text -match [string]$pattern) { return $true } }
    return $false
}

function Get-TargetAdapters {
    param($Adapters)
    if ($Mode -eq 'StopOtherClients' -or $Mode -eq 'PrepareSwitch') {
        throw "$Mode 已在 v0.4.0-beta 停止执行。新版要求先一键退出全部代理并恢复普通网络，再由用户手动只打开一个客户端。"
    }
    if ($Mode -eq 'StopSelectedClients') {
        $ids = @($TargetClientIds | ForEach-Object { @($_ -split ',') } | Where-Object { $_ } | Select-Object -Unique)
        if ($ids.Count -eq 0) { throw 'StopSelectedClients 必须提供 -TargetClientIds。' }
        $unknown = @($ids | Where-Object { @($Adapters.id) -notcontains $_ })
        if ($unknown.Count -gt 0) { throw "无法识别目标客户端：$($unknown -join '、')" }
        return @($Adapters | Where-Object { $ids -contains $_.id })
    }
    return @($Adapters)
}

function Get-OwnershipReport {
    $output = & $ScannerPath -AdapterPath $AdapterPath -PassThru -NoWriteReport -Quiet -SkipPathHealth
    return @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'summary' }) | Select-Object -Last 1
}

function Get-RegistryValueSafe {
    param($Item, [string]$Name)
    if ($null -eq $Item) { return $null }
    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SafeEnvironmentBackupValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Value -match '(?i)(https?://|socks5?://)[^/@\s]+@') { return '[包含认证信息，未写入备份]' }
    if ($Value -match '(?i)^https?://[^\s?]+\?.+') { return '[URL 包含查询参数，未写入备份]' }
    return $Value
}

function New-NetworkBackup {
    param($Adapters, $Report)
    if (-not (Test-Path -LiteralPath $BackupDirectory)) { New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null }
    $internetPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $internet = Get-ItemProperty -LiteralPath $internetPath -ErrorAction SilentlyContinue
    $services = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in $Adapters) {
        foreach ($pattern in @($adapter.servicePatterns)) {
            foreach ($service in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [string]$pattern })) {
                if (@($services | Where-Object { $_.Name -eq $service.Name }).Count -gt 0) { continue }
                $startType = ''; try { $startType = [string]$service.StartType } catch {}
                $services.Add([pscustomobject]@{ Name = $service.Name; Status = [string]$service.Status; StartType = $startType })
            }
        }
    }
    $environment = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('User', 'Machine')) {
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            $environment.Add([pscustomobject]@{ Scope = $scope; Name = $name; Value = Get-SafeEnvironmentBackupValue $value })
        }
    }
    $backup = [pscustomobject][ordered]@{
        version = $Script:Version
        createdAt = (Get-Date).ToString('o')
        mode = $Mode
        keepClient = $KeepClient
        targetClientIds = @($TargetClientIds)
        systemProxy = [pscustomobject]@{
            ProxyEnable = Get-RegistryValueSafe $internet 'ProxyEnable'
            ProxyServer = Get-SafeEnvironmentBackupValue ([string](Get-RegistryValueSafe $internet 'ProxyServer'))
            ProxyOverride = [string](Get-RegistryValueSafe $internet 'ProxyOverride')
            AutoConfigURL = Get-SafeEnvironmentBackupValue ([string](Get-RegistryValueSafe $internet 'AutoConfigURL'))
        }
        winHttp = [string]$Report.winHttp.Raw
        environment = $environment.ToArray()
        services = $services.ToArray()
        tunOwners = @($Report.owners.tun)
        networkAdapters = @($Report.network.Adapters)
        defaultRoutes = @($Report.network.Routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
        dns = @($Report.network.Dns)
        clients = @($Report.clients | Select-Object Id, Name, UiProcesses, CoreProcesses, HelperProcesses, Services)
    }
    $path = Join-Path $BackupDirectory ("network-backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $backup | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    $Script:CurrentBackupPath = $path
    Write-ActionLog 'INFO' '创建备份' $path '成功'
    return $path
}

function Initialize-WinInetApi {
    if (-not ('NetworkRescue.WinInet' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace NetworkRescue {
    public static class WinInet {
        [DllImport("wininet.dll", SetLastError=true)]
        public static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);
    }
}
'@
    }
}

function Send-ProxySettingsChanged {
    Initialize-WinInetApi
    [NetworkRescue.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [NetworkRescue.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Disable-SystemProxy {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $current = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if ([int]$current.ProxyEnable -eq 0) { Write-ActionLog 'INFO' '关闭系统代理' 'HKCU ProxyEnable' '已经关闭'; return }
    if ($PSCmdlet.ShouldProcess('Windows 当前用户系统代理', '关闭 ProxyEnable')) {
        Set-ItemProperty -LiteralPath $path -Name ProxyEnable -Type DWord -Value 0
        Send-ProxySettingsChanged
        $verified = Get-ItemProperty -LiteralPath $path
        if ([int]$verified.ProxyEnable -ne 0) { throw '系统代理关闭后复核失败。' }
        Write-ActionLog 'ACTION' '关闭系统代理' ([string]$current.ProxyServer) '成功'
    }
}

function Test-LocalProxyText {
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '(?i)(127\.0\.0\.1|localhost|\[::1\]|::1)\s*:\s*\d+')
}

function Reset-LocalWinHttpProxy {
    $raw = ((& netsh.exe winhttp show proxy 2>&1) -join "`n")
    if (-not (Test-LocalProxyText $raw)) { Write-ActionLog 'INFO' '重置 WinHTTP' 'WinHTTP' '不是本地代理，无需修改'; return }
    if (-not (Test-IsAdministrator)) { Write-ActionLog 'WARN' '重置 WinHTTP' 'WinHTTP' '需要管理员权限，已跳过'; return }
    if ($PSCmdlet.ShouldProcess('WinHTTP 本地代理', '重置为直接访问')) {
        $output = (& netsh.exe winhttp reset proxy 2>&1) -join ' '
        Write-ActionLog 'ACTION' '重置 WinHTTP' '本地代理' $output
    }
}

function Clear-LocalProxyEnvironment {
    if ($KeepProxyEnvironment) { Write-ActionLog 'INFO' '清理代理环境变量' 'User/Machine' '按参数保留'; return }
    foreach ($scope in @('User', 'Machine')) {
        if ($scope -eq 'Machine' -and -not (Test-IsAdministrator)) { continue }
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (-not (Test-LocalProxyText $value)) { continue }
            if ($PSCmdlet.ShouldProcess("$scope/$name", "删除本地代理环境变量 $value")) {
                [Environment]::SetEnvironmentVariable($name, $null, $scope)
                Write-ActionLog 'ACTION' '删除本地代理环境变量' "$scope/$name" '成功（只影响新启动的进程）'
            }
        }
    }
}

function Get-LocalProxyEnvironmentTargets {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('User', 'Machine')) {
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (Test-LocalProxyText $value) {
                $rows.Add([pscustomobject]@{ Scope=$scope; Name=$name; Value=$value })
            }
        }
    }
    return $rows.ToArray()
}

function Initialize-EnvironmentBroadcastApi {
    if ('NetworkRescue.EnvironmentBroadcast' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace NetworkRescue {
    public static class EnvironmentBroadcast {
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    }
}
'@
}

function Send-EnvironmentSettingsChanged {
    Initialize-EnvironmentBroadcastApi
    $result = [IntPtr]::Zero
    [void][NetworkRescue.EnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'Environment', 2, 3000, [ref]$result)
}

function Get-ValidatedApplicationProxyTarget {
    param([string]$Endpoint)
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { throw '没有提供当前代理端点。' }
    $match = [regex]::Match($Endpoint, '(?i)^(?:https?://|socks5?://)?(127\.0\.0\.1|localhost|\[?::1\]?):(?<port>\d{1,5})$')
    if (-not $match.Success) { throw '只允许同步已确认的本地代理端点。' }
    $port = [int]$match.Groups['port'].Value
    if ($port -lt 1 -or $port -gt 65535) { throw '代理端口无效。' }
    $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $listener) {
        foreach ($line in @(& netstat.exe -ano -p tcp 2>$null)) {
            if ($line -match "^\s*TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0|\[?::1\]?|\[?::\]?):$port\s+\S+\s+LISTENING\s+(?<pid>\d+)") {
                $listener = [pscustomobject]@{ OwningProcess=[int]$Matches['pid'] }
                break
            }
        }
    }
    if ($null -eq $listener) { throw "本地代理端口 $port 当前无人监听，拒绝写入环境变量。" }
    return [pscustomobject]@{ Text="127.0.0.1:$port"; Port=$port; Pid=[int]$listener.OwningProcess }
}

function Sync-ApplicationProxyEnvironment {
    $target = Get-ValidatedApplicationProxyTarget -Endpoint $ProxyEndpoint
    $portOwner = $report.portOwners | Where-Object { $_.Port -eq $target.Port -and $_.Pid -eq $target.Pid } | Select-Object -First 1
    if ($null -eq $portOwner) { throw "无法把 $($target.Text) 稳定映射到已知客户端，拒绝写入环境变量。" }
    $client = $report.clients | Where-Object { $_.Id -eq $portOwner.ClientId } | Select-Object -First 1
    if ($null -eq $client) { throw '无法读取代理客户端协议能力。' }
    $capabilities = @($client.ProxyCapabilities)
    $protocol = if ($ProxyProtocol -eq 'auto') { if ($capabilities -contains 'mixed') { 'mixed' } else { 'http' } } else { $ProxyProtocol }
    if ($protocol -eq 'mixed' -and $capabilities -notcontains 'mixed') { throw "$($client.Name) 适配器未声明 Mixed 端口能力。" }
    if ($protocol -eq 'http' -and @($capabilities | Where-Object { $_ -in @('http','mixed') }).Count -eq 0) { throw "$($client.Name) 适配器未声明 HTTP 代理能力。" }
    $httpValue = "http://$($target.Text)"
    $allValue = if ($protocol -eq 'mixed') { "socks5://$($target.Text)" } else { $httpValue }
    foreach ($item in @(
        @{ Name='HTTP_PROXY'; Value=$httpValue },
        @{ Name='HTTPS_PROXY'; Value=$httpValue },
        @{ Name='ALL_PROXY'; Value=$allValue }
    )) {
        if ($PSCmdlet.ShouldProcess("User/$($item.Name)", "设置为 $($item.Value)")) {
            [Environment]::SetEnvironmentVariable($item.Name, $item.Value, 'User')
            Write-ActionLog 'ACTION' '同步应用代理环境变量' "User/$($item.Name)" $item.Value
        }
    }
    Send-EnvironmentSettingsChanged
    Write-ActionLog 'INFO' '应用代理同步完成' $target.Text '已运行的 Codex、终端和其他应用需要重启后才能读取新值'
}

function Clear-ApplicationProxyEnvironment {
    foreach ($item in @(Get-LocalProxyEnvironmentTargets | Where-Object { $_.Scope -eq 'User' })) {
        if ($PSCmdlet.ShouldProcess("User/$($item.Name)", "删除本地代理环境变量 $($item.Value)")) {
            [Environment]::SetEnvironmentVariable($item.Name, $null, 'User')
            Write-ActionLog 'ACTION' '清除应用代理环境变量' "User/$($item.Name)" '成功'
        }
    }
    Send-EnvironmentSettingsChanged
    Write-ActionLog 'INFO' '应用代理清理完成' 'User' '已运行的 Codex、终端和其他应用需要重启后才能读取新值'
}

function Stop-TargetServices {
    param($TargetAdapters)
    if ($Script:HelperAvailable -and -not $Script:DeferHelper -and -not (Test-IsAdministrator) -and -not $WhatIfPreference) {
        Invoke-HelperOperation -Operation StopServices -TargetAdapters $TargetAdapters | Out-Null
        return
    }
    foreach ($adapter in $TargetAdapters) {
        foreach ($pattern in @($adapter.servicePatterns)) {
            foreach ($service in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [string]$pattern })) {
                if ($service.Status -eq 'Stopped') { Write-ActionLog 'INFO' '停止服务' $service.Name '已经停止'; continue }
                if ($PSCmdlet.ShouldProcess("服务 $($service.Name)", '停止')) {
                    try {
                        Stop-Service -Name $service.Name -Force -ErrorAction Stop
                        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10))
                        Write-ActionLog 'ACTION' '停止服务' $service.Name '成功'
                    }
                    catch { Write-ActionLog 'ERROR' '停止服务' $service.Name $_.Exception.Message }
                }
            }
        }
    }
}

function Close-TargetUiGracefully {
    param($TargetAdapters, [int]$WaitSeconds = 5)
    $requested = New-Object System.Collections.Generic.List[int]
    foreach ($adapter in $TargetAdapters) {
        $uiPathProperty = $adapter.PSObject.Properties['uiPathPatterns']
        $uiPathPatterns = if ($null -ne $uiPathProperty) { @($uiPathProperty.Value) } else { @() }
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            if (-not (Test-PatternList $process.ProcessName $adapter.uiProcessPatterns)) { continue }
            $processPath = try { [string]$process.Path } catch { '' }
            if ($uiPathPatterns.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($processPath) -or -not (Test-PatternList $processPath $uiPathPatterns))) { continue }
            if ($PSCmdlet.ShouldProcess("客户端界面 $($process.ProcessName) ($($process.Id))", '发送正常关闭请求')) {
                try {
                    if ($process.MainWindowHandle -ne 0 -and $process.CloseMainWindow()) {
                        $requested.Add([int]$process.Id)
                        Write-ActionLog 'ACTION' '请求客户端正常退出' "$($adapter.name)/$($process.ProcessName)/$($process.Id)" '已发送关闭窗口请求'
                    }
                    else {
                        Write-ActionLog 'INFO' '请求客户端正常退出' "$($adapter.name)/$($process.ProcessName)/$($process.Id)" '没有可关闭的主窗口，稍后按残留处理'
                    }
                }
                catch { Write-ActionLog 'WARN' '请求客户端正常退出' "$($adapter.name)/$($process.ProcessName)/$($process.Id)" $_.Exception.Message }
            }
        }
    }
    if ($requested.Count -eq 0 -or $WhatIfPreference) { return }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@($requested | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }).Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }
}

function Stop-TargetProcesses {
    param($TargetAdapters)
    $currentPid = $PID
    foreach ($adapter in $TargetAdapters) {
        $safeProperty = $adapter.PSObject.Properties['safeStopProcessPatterns']
        $patterns = if ($null -ne $safeProperty) { @($safeProperty.Value) } else { @($adapter.uiProcessPatterns) + @($adapter.coreProcessPatterns) }
        $safePathProperty = $adapter.PSObject.Properties['safeStopPathPatterns']
        $safePathPatterns = if ($null -ne $safePathProperty) { @($safePathProperty.Value) } else { @() }
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($process.Id -eq $currentPid -or -not (Test-PatternList $process.ProcessName $patterns)) { continue }
            $candidatePath = try { [string]$process.Path } catch { '' }
            if ($safePathPatterns.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($candidatePath) -or -not (Test-PatternList $candidatePath $safePathPatterns))) { continue }
            if ($PSCmdlet.ShouldProcess("进程 $($process.ProcessName) ($($process.Id))", '关闭')) {
                try {
                    $expectedId = [int]$process.Id
                    $expectedName = [string]$process.ProcessName
                    $expectedPath = try { [string]$process.Path } catch { '' }
                    $expectedStart = try { $process.StartTime.ToUniversalTime().ToString('o') } catch { '' }
                    $current = Get-Process -Id $expectedId -ErrorAction Stop
                    $currentPath = try { [string]$current.Path } catch { '' }
                    $currentStart = try { $current.StartTime.ToUniversalTime().ToString('o') } catch { '' }
                    if ($current.ProcessName -ne $expectedName -or -not (Test-PatternList $current.ProcessName $patterns)) { throw '进程身份已经变化，拒绝结束。' }
                    if ($safePathPatterns.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($currentPath) -or -not (Test-PatternList $currentPath $safePathPatterns))) { throw '进程路径不属于目标客户端，拒绝结束。' }
                    if ($expectedPath -and $currentPath -and -not [string]::Equals($expectedPath, $currentPath, [StringComparison]::OrdinalIgnoreCase)) { throw '进程路径已经变化，拒绝结束。' }
                    if ($expectedStart -and $currentStart -and $expectedStart -ne $currentStart) { throw '进程启动时间已经变化，拒绝结束。' }
                    Stop-Process -Id $expectedId -Force -ErrorAction Stop
                    Write-ActionLog 'ACTION' '结束残留代理进程' "$($adapter.name)/$expectedName/$expectedId" '成功（已复核 PID、名称、路径和启动时间）'
                }
                catch { Write-ActionLog 'ERROR' '关闭客户端进程' "$($adapter.name)/$($process.ProcessName)" $_.Exception.Message }
            }
        }
    }
    if ($Script:HelperAvailable -and -not $Script:DeferHelper -and -not (Test-IsAdministrator) -and -not $WhatIfPreference) {
        Invoke-HelperOperation -Operation KillProcesses -TargetAdapters $TargetAdapters | Out-Null
    }
}

function Test-AdapterMatchesClient {
    param([string]$Text, $TargetAdapters)
    foreach ($adapter in $TargetAdapters) {
        if (Test-PatternList $Text $adapter.tunInterfacePatterns) { return $true }
    }
    return $false
}

function Remove-KnownTunTakeover {
    param($TargetAdapters)
    if ($SkipTunCleanup) { Write-ActionLog 'INFO' '清理 TUN' '已知客户端' '按参数跳过'; return }
    if ($Script:HelperAvailable -and -not $Script:DeferHelper -and -not (Test-IsAdministrator) -and -not $WhatIfPreference) {
        Invoke-HelperOperation -Operation CleanupTun -TargetAdapters $TargetAdapters | Out-Null
        return
    }
    if (-not (Test-IsAdministrator) -and -not $WhatIfPreference) { Write-ActionLog 'WARN' '清理 TUN' '已知客户端' '需要管理员权限，已跳过'; return }

    $netAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.NextHop -like '198.18.*' -or $_.DestinationPrefix -like '198.18.*'
    })
    foreach ($route in $routes) {
        $netAdapter = $netAdapters | Where-Object { $_.InterfaceIndex -eq $route.InterfaceIndex } | Select-Object -First 1
        $text = if ($null -ne $netAdapter) { "$($netAdapter.Name) $($netAdapter.InterfaceDescription)" } else { [string]$route.InterfaceAlias }
        $knownByName = Test-AdapterMatchesClient $text $TargetAdapters
        $knownByRange = ($route.NextHop -like '198.18.*' -or $route.DestinationPrefix -like '198.18.*')
        if (-not $knownByName -or -not $knownByRange) { continue }

        $routeTarget = "$($route.DestinationPrefix) → $($route.NextHop)，接口 $($route.InterfaceAlias)#$($route.InterfaceIndex)"
        if ($PSCmdlet.ShouldProcess($routeTarget, '删除明确归属的 TUN 默认路由')) {
            try {
                Remove-NetRoute -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -NextHop $route.NextHop -Confirm:$false -ErrorAction Stop
                Write-ActionLog 'ACTION' '删除 TUN 默认路由' $routeTarget '成功'
            }
            catch { Write-ActionLog 'ERROR' '删除 TUN 默认路由' $routeTarget $_.Exception.Message }
        }
        if ($null -ne $netAdapter -and $netAdapter.Status -ne 'Disabled') {
            if ($PSCmdlet.ShouldProcess("TUN 网卡 $($netAdapter.Name)", '清理已知代理 DNS')) {
                try {
                    Set-DnsClientServerAddress -InterfaceIndex $netAdapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    Write-ActionLog 'ACTION' '清理 TUN DNS' $netAdapter.Name '成功'
                }
                catch { Write-ActionLog 'WARN' '清理 TUN DNS' $netAdapter.Name $_.Exception.Message }
            }
            if ($PSCmdlet.ShouldProcess("TUN 网卡 $($netAdapter.Name)", '禁用')) {
                try {
                    Disable-NetAdapter -InterfaceIndex $netAdapter.InterfaceIndex -Confirm:$false -ErrorAction Stop
                    Write-ActionLog 'ACTION' '禁用 TUN 网卡' $netAdapter.Name '成功'
                }
                catch { Write-ActionLog 'ERROR' '禁用 TUN 网卡' $netAdapter.Name $_.Exception.Message }
            }
        }
    }
}

function Reset-PhysicalDns {
    if ($Script:HelperAvailable -and -not (Test-IsAdministrator) -and -not $WhatIfPreference) {
        Invoke-HelperOperation -Operation ResetDns | Out-Null
        return
    }
    if (-not (Test-IsAdministrator) -and -not $WhatIfPreference) { throw '重置 DNS 需要管理员权限。' }
    $excludedPattern = '(?i)tun|wintun|mihomo|clash|flclash|lmclient|globalcloud|abysswalker|vEthernet|Hyper-V|WSL|Virtual|Loopback|Bluetooth'
    foreach ($adapter in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $text = "$($adapter.Name) $($adapter.InterfaceDescription)"
        if ($text -match $excludedPattern) { continue }
        if ($PSCmdlet.ShouldProcess("网卡 $($adapter.Name)", '把 DNS 恢复为自动获取')) {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                Write-ActionLog 'ACTION' '重置 DNS' $adapter.Name '已恢复为自动获取'
            }
            catch { Write-ActionLog 'ERROR' '重置 DNS' $adapter.Name $_.Exception.Message }
        }
    }
}

function Clear-DnsCacheSafe {
    if ($PSCmdlet.ShouldProcess('Windows DNS 缓存', '清空')) {
        try { Clear-DnsClientCache -ErrorAction Stop; Write-ActionLog 'ACTION' '清空 DNS 缓存' 'Windows' '成功' }
        catch { Write-ActionLog 'WARN' '清空 DNS 缓存' 'Windows' $_.Exception.Message }
    }
}

function Test-DirectInternet {
    if (Test-Path -LiteralPath $Script:PathHealthScript) {
        try {
            $output = & $Script:PathHealthScript -SkipProxy -TimeoutSeconds 6 -PassThru
            $health = @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'schemaVersion' }) | Select-Object -Last 1
            if ($null -ne $health) { return [bool]$health.direct.healthy }
        }
        catch { Write-ActionLog 'WARN' '验证普通网络' '多目标探测' $_.Exception.Message }
    }
    try {
        $code = & curl.exe --noproxy '*' -sS -L -o NUL --max-time 10 --connect-timeout 4 -w '%{http_code}' 'http://www.msftconnecttest.com/connecttest.txt' 2>$null
        return ($code -match '^20[04]$')
    }
    catch { return $false }
}

function Get-EmergencyVerification {
    param($Report, $TargetAdapters, [bool]$DirectConfirmed)
    $runningClients = @($Report.clients | Where-Object {
        @($_.UiProcesses).Count -gt 0 -or @($_.CoreProcesses).Count -gt 0 -or @($_.HelperProcesses).Count -gt 0
    })
    $runningServices = @($Report.clients | ForEach-Object { @($_.Services) } | Where-Object { $_.Status -eq 'Running' } | Select-Object -ExpandProperty Name -Unique)
    $knownTunOwners = @($Report.owners.tun | Where-Object { $_.ClientId -ne 'unknown' })
    $knownRoutes = New-Object System.Collections.Generic.List[object]
    foreach ($route in @($Report.network.Routes | Where-Object { $_.NextHop -like '198.18.*' -or $_.DestinationPrefix -like '198.18.*' })) {
        $adapter = $Report.network.Adapters | Where-Object { $_.InterfaceIndex -eq $route.InterfaceIndex } | Select-Object -First 1
        $text = if ($null -ne $adapter) { "$($adapter.Name) $($adapter.InterfaceDescription)" } else { [string]$route.InterfaceAlias }
        if (Test-AdapterMatchesClient -Text $text -TargetAdapters $TargetAdapters) { $knownRoutes.Add($route) }
    }
    $localEnvironment = @($Report.environmentProxies | Where-Object { $_.Scope -in @('User','Machine') -and $null -ne $_.Endpoint })
    $systemProxyClosed = (-not [bool]$Report.systemProxy.Enabled)
    $winHttpLocal = ($null -ne $Report.winHttp.Endpoint)
    $residueCleaned = (
        $runningClients.Count -eq 0 -and
        $runningServices.Count -eq 0 -and
        @($Report.portOwners).Count -eq 0 -and
        $knownTunOwners.Count -eq 0 -and
        $knownRoutes.Count -eq 0 -and
        -not $winHttpLocal -and
        $localEnvironment.Count -eq 0
    )
    return [pscustomobject][ordered]@{
        systemProxyClosed = $systemProxyClosed
        proxyResidueCleaned = $residueCleaned
        directConfirmed = $DirectConfirmed
        runningClients = @($runningClients | Select-Object Id, Name, UiProcesses, CoreProcesses, HelperProcesses)
        runningServices = @($runningServices)
        portOwners = @($Report.portOwners)
        tunOwners = @($knownTunOwners)
        known198Routes = @($knownRoutes.ToArray())
        localWinHttp = $winHttpLocal
        localProxyEnvironment = @($localEnvironment | Select-Object Scope, Name, Value)
    }
}

function Test-EmergencyPrivilegeResidue {
    param($Verification)
    return (
        @($Verification.runningClients).Count -gt 0 -or
        @($Verification.runningServices).Count -gt 0 -or
        @($Verification.tunOwners).Count -gt 0 -or
        @($Verification.known198Routes).Count -gt 0 -or
        [bool]$Verification.localWinHttp -or
        @($Verification.localProxyEnvironment | Where-Object { $_.Scope -eq 'Machine' }).Count -gt 0
    )
}

function Invoke-EmergencyCleanup {
    param($TargetAdapters)
    $Script:DeferHelper = $true
    Disable-SystemProxy
    Close-TargetUiGracefully -TargetAdapters $TargetAdapters -WaitSeconds 5
    Stop-TargetServices -TargetAdapters $TargetAdapters
    Stop-TargetProcesses -TargetAdapters $TargetAdapters
    Remove-KnownTunTakeover -TargetAdapters $TargetAdapters
    Reset-LocalWinHttpProxy
    Clear-LocalProxyEnvironment
    Clear-DnsCacheSafe
    $Script:DeferHelper = $false

    if ($WhatIfPreference) { return $null }

    $firstReport = Get-OwnershipReport
    $firstVerification = Get-EmergencyVerification -Report $firstReport -TargetAdapters $TargetAdapters -DirectConfirmed $false
    if (Test-EmergencyPrivilegeResidue -Verification $firstVerification) {
        if ($Script:HelperAvailable -and -not (Test-IsAdministrator)) {
            [void](Invoke-HelperOperation -Operation StopServices -TargetAdapters $TargetAdapters)
            [void](Invoke-HelperOperation -Operation KillProcesses -TargetAdapters $TargetAdapters)
            [void](Invoke-HelperOperation -Operation CleanupTun -TargetAdapters $TargetAdapters)
            [void](Invoke-HelperOperation -Operation RestoreMachineDirect -TargetAdapters $TargetAdapters)
        }
        elseif ($AutoElevate -and -not (Test-IsAdministrator)) {
            Write-ActionLog 'WARN' '请求管理员权限' '受保护的核心、服务或 TUN 残留' '普通权限清理后仍有残留，准备请求一次 UAC'
            try { Start-ElevatedSelf }
            catch { Write-ActionLog 'ERROR' '请求管理员权限' 'UAC' "授权被取消或失败：$($_.Exception.Message)" }
        }
    }

    $finalReport = Get-OwnershipReport
    $directOk = Test-DirectInternet
    Write-ActionLog $(if($directOk){'INFO'}else{'WARN'}) '验证普通网络' 'Windows 联网探针和国内探针' $(if($directOk){'成功'}else{'失败或超时'})
    return (Get-EmergencyVerification -Report $finalReport -TargetAdapters $TargetAdapters -DirectConfirmed $directOk)
}

function Restore-FromBackup {
    if ([string]::IsNullOrWhiteSpace($BackupPath) -or -not (Test-Path -LiteralPath $BackupPath)) { throw '请提供有效的 -BackupPath。' }
    $backup = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $proxy = $backup.systemProxy
    if ($proxy.ProxyServer -eq '[包含认证信息，未写入备份]') { throw '备份中的代理包含认证信息，出于安全原因未保存，无法自动恢复。' }
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($PSCmdlet.ShouldProcess('Windows 当前用户系统代理', "恢复备份 $BackupPath")) {
        if ($null -ne $proxy.ProxyServer) { Set-ItemProperty -LiteralPath $path -Name ProxyServer -Type String -Value ([string]$proxy.ProxyServer) }
        if ($null -ne $proxy.ProxyOverride) { Set-ItemProperty -LiteralPath $path -Name ProxyOverride -Type String -Value ([string]$proxy.ProxyOverride) }
        if ($null -ne $proxy.ProxyEnable) { Set-ItemProperty -LiteralPath $path -Name ProxyEnable -Type DWord -Value ([int]$proxy.ProxyEnable) }
        Send-ProxySettingsChanged
        Write-ActionLog 'ACTION' '恢复系统代理备份' $BackupPath '成功'
    }
    foreach ($item in @($backup.environment)) {
        if ($item.Value -eq '[包含认证信息，未写入备份]') { continue }
        if ($item.Scope -eq 'Machine' -and -not (Test-IsAdministrator)) { continue }
        if ($PSCmdlet.ShouldProcess("$($item.Scope)/$($item.Name)", '恢复代理环境变量')) {
            [Environment]::SetEnvironmentVariable([string]$item.Name, $item.Value, [string]$item.Scope)
            Write-ActionLog 'ACTION' '恢复环境变量' "$($item.Scope)/$($item.Name)" '成功'
        }
    }
    foreach ($service in @($backup.services | Where-Object { $_.Status -eq 'Running' })) {
        if ($PSCmdlet.ShouldProcess("服务 $($service.Name)", '恢复为运行状态')) {
            try { Start-Service -Name $service.Name -ErrorAction Stop; Write-ActionLog 'ACTION' '恢复服务' $service.Name '成功' }
            catch { Write-ActionLog 'ERROR' '恢复服务' $service.Name $_.Exception.Message }
        }
    }
    Write-ActionLog 'WARN' '恢复备份' $BackupPath '未自动恢复 TUN 路由；请由对应客户端重新建立 TUN'
}

function Invoke-RepairSelfTest {
    $adapters = Get-Adapters
    $targets = Get-TargetAdapters -Adapters $adapters
    if ($targets.Count -ne $adapters.Count) { throw 'Status 模式目标适配器数量异常。' }
    if (-not (Test-LocalProxyText 'http://127.0.0.1:7890')) { throw '本地代理识别失败。' }
    if (Test-LocalProxyText 'http://proxy.example.com:8080') { throw '远程代理被误判为本地代理。' }
    if ((Get-SafeEnvironmentBackupValue 'http://user:pass@127.0.0.1:7890') -notmatch '未写入备份') { throw '敏感代理备份保护失败。' }
    $allSafePatterns = @($adapters | ForEach-Object { @($_.safeStopProcessPatterns) })
    if (Test-PatternList 'unknown-proxy-core' $allSafePatterns) { throw '未知进程被错误纳入结束白名单。' }
    $partyAdapter = $adapters | Where-Object { $_.id -eq 'clash_party' } | Select-Object -First 1
    if ($null -eq $partyAdapter) { throw '缺少 Clash Party 适配器。' }
    $partyPathPatterns = @($partyAdapter.safeStopPathPatterns)
    if (-not (Test-PatternList 'D:\Apps\Clash Party\resources\sidecar\mihomo.exe' $partyPathPatterns)) { throw 'Clash Party 核心安全路径未被允许。' }
    if (Test-PatternList 'D:\Apps\Other Client\mihomo.exe' $partyPathPatterns) { throw '其他客户端的通用 mihomo 被 Clash Party 安全路径错误允许。' }
    $vergeAdapter = $adapters | Where-Object { $_.id -eq 'clash_verge' } | Select-Object -First 1
    if (Test-PatternList 'mihomo' $vergeAdapter.coreProcessPatterns) { throw 'Clash Verge 仍然按通用 mihomo 进程名抢占归属。' }
    $fixtureReport = [pscustomobject]@{
        systemProxy=[pscustomobject]@{Enabled=$false}; winHttp=[pscustomobject]@{Endpoint=$null}; environmentProxies=@(); portOwners=@()
        clients=@([pscustomobject]@{Id='globalcloud';Name='全球云';UiProcesses=@();CoreProcesses=@();HelperProcesses=@([pscustomobject]@{Id=10});Services=@([pscustomobject]@{Name='globalcloudHelperService';Status='Running'})})
        owners=[pscustomobject]@{tun=@()}; network=[pscustomobject]@{Routes=@();Adapters=@()}
    }
    $fixtureVerification = Get-EmergencyVerification -Report $fixtureReport -TargetAdapters $adapters -DirectConfirmed $true
    if ($fixtureVerification.proxyResidueCleaned) { throw '仅后台 Helper 服务存在时被错误判为清场完成。' }
    if (-not (Test-EmergencyPrivilegeResidue -Verification $fixtureVerification)) { throw '后台 Helper 残留没有触发高权限清理判断。' }
    $sourceText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    if (-not $sourceText.Contains('PrepareSwitch 已在 v0.4.0-beta 停止执行') -and -not $sourceText.Contains('$Mode 已在 v0.4.0-beta 停止执行')) { throw '旧安全切换模式没有明确停止执行。' }
    $rotationFile = Join-Path ([IO.Path]::GetTempPath()) "network-rescue-repair-rotation-$PID.log"
    try {
        [IO.File]::WriteAllBytes($rotationFile, (New-Object byte[] 96))
        Invoke-FileRotation -Path $rotationFile -MaxBytes 100 -ArchiveCount 3 -IncomingBytes 10
        if (-not (Test-Path -LiteralPath "$rotationFile.1") -or (Test-Path -LiteralPath $rotationFile)) { throw '修复动作日志轮转测试失败。' }
    }
    finally {
        Remove-Item -LiteralPath $rotationFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
        foreach ($index in 1..3) { Remove-Item -LiteralPath "$rotationFile.$index" -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
    Write-Host '修复引擎自检通过：清场目标、未知进程保护、Helper 残留、敏感备份保护和日志轮转正常。' -ForegroundColor Green
}

if ($Mode -eq 'SelfTest') { Invoke-RepairSelfTest; return }

if ($Mode -in @('StopOtherClients','PrepareSwitch')) {
    throw "$Mode 已在 v0.4.0-beta 停止执行。请改用 -Mode EmergencyDirect，确认普通网络恢复后再手动只打开一个代理客户端。"
}

$Script:HelperAvailable = Test-HelperAvailable
if ($AutoElevate -and (Test-ModeNeedsAdministrator) -and -not (Test-IsAdministrator) -and -not $WhatIfPreference -and (-not $Script:HelperAvailable -or -not (Test-ModeCanUseHelper))) {
    Start-ElevatedSelf
}

$adapters = Get-Adapters
$report = Get-OwnershipReport

if ($Mode -eq 'Status') {
    Write-Host "有效 Owner：$($report.summary.effectiveOwner)"
    Write-Host "系统代理：$($report.summary.systemProxyStatus)"
    Write-Host "TUN Owner：$($report.summary.tunOwner)"
    Write-Host "冲突数量：$(@($report.conflicts).Count)"
    return
}

if ($Mode -eq 'BackupOnly') {
    New-NetworkBackup -Adapters $adapters -Report $report | Out-Null
    Write-Host "备份完成：$Script:CurrentBackupPath" -ForegroundColor Green
    return
}

if ($Mode -eq 'RestoreBackup') { Restore-FromBackup; return }

$targetAdapters = Get-TargetAdapters -Adapters $adapters
if ($WhatIfPreference) {
    $Script:CurrentBackupPath = 'WhatIf 预演未创建备份'
}
else {
    New-NetworkBackup -Adapters $adapters -Report $report | Out-Null
}

switch ($Mode) {
    'RestoreDirect' {
        Disable-SystemProxy
        Reset-LocalWinHttpProxy
        Clear-LocalProxyEnvironment
        if ($Script:HelperAvailable -and -not (Test-IsAdministrator)) { Invoke-HelperOperation -Operation RestoreMachineDirect | Out-Null }
        Clear-DnsCacheSafe
    }
    'StopServices' {
        Stop-TargetServices -TargetAdapters $targetAdapters
    }
    'StopOtherClients' {
        throw 'StopOtherClients 已停止执行。'
    }
    'StopSelectedClients' {
        Stop-TargetServices -TargetAdapters $targetAdapters
        Stop-TargetProcesses -TargetAdapters $targetAdapters
        Remove-KnownTunTakeover -TargetAdapters $targetAdapters
    }
    'PrepareSwitch' {
        throw 'PrepareSwitch 已停止执行。'
    }
    'EmergencyDirect' {
        $emergencyVerification = Invoke-EmergencyCleanup -TargetAdapters $targetAdapters
    }
    'StopAllClients' {
        Write-ActionLog 'INFO' '兼容模式映射' 'StopAllClients' '已映射到 EmergencyDirect'
        $emergencyVerification = Invoke-EmergencyCleanup -TargetAdapters $targetAdapters
    }
    'ResetDns' {
        Reset-PhysicalDns
        Clear-DnsCacheSafe
    }
    'SyncApplicationProxy' {
        Sync-ApplicationProxyEnvironment
    }
    'ClearApplicationProxy' {
        Clear-ApplicationProxyEnvironment
    }
}

if (-not $WhatIfPreference -and $Mode -in @('RestoreDirect')) {
    $directOk = Test-DirectInternet
    Write-ActionLog $(if($directOk){'INFO'}else{'WARN'}) '验证普通网络' '绕过代理请求' $(if($directOk){'成功'}else{'失败或超时'})
}

if ($Mode -in @('EmergencyDirect','StopAllClients')) {
    Write-Host ''
    if ($WhatIfPreference) {
        Write-Host '预演完成：未修改系统。' -ForegroundColor Cyan
        Write-Host "操作前备份：$Script:CurrentBackupPath"
        return
    }
    $allComplete = ($emergencyVerification.systemProxyClosed -and $emergencyVerification.proxyResidueCleaned -and $emergencyVerification.directConfirmed)
    $status = if ($allComplete) { 'Completed' } else { 'Partial' }
    $message = if ($allComplete) { '普通网络已经恢复；如需代理，请只打开一个客户端。' } else { '清场部分完成，请查看仍存在的代理残留或普通网络探测结果。' }
    Write-RepairResult -Status $status -SystemProxyClosed ([bool]$emergencyVerification.systemProxyClosed) -ResidueCleaned ([bool]$emergencyVerification.proxyResidueCleaned) -DirectConfirmed ([bool]$emergencyVerification.directConfirmed) -Verification $emergencyVerification -Message $message
    Write-Host "系统代理已关闭：$(if($emergencyVerification.systemProxyClosed){'是'}else{'否'})" -ForegroundColor $(if($emergencyVerification.systemProxyClosed){'Green'}else{'Yellow'})
    Write-Host "代理残留已清理：$(if($emergencyVerification.proxyResidueCleaned){'是'}else{'否'})" -ForegroundColor $(if($emergencyVerification.proxyResidueCleaned){'Green'}else{'Yellow'})
    Write-Host "普通网络已确认恢复：$(if($emergencyVerification.directConfirmed){'是'}else{'否'})" -ForegroundColor $(if($emergencyVerification.directConfirmed){'Green'}else{'Yellow'})
    Write-Host $message -ForegroundColor $(if($allComplete){'Green'}else{'Yellow'})
    Write-Host "操作前备份：$Script:CurrentBackupPath"
    Write-Host "结果文件：$Script:ResultPath"
    Write-Host "动作日志：$Script:ActionLogPath"
    Write-Host '提示：旧代理环境变量已经清理；Codex、终端和其他已运行应用需要重启后才能读取新值。' -ForegroundColor Yellow
    if (-not $allComplete) { exit 2 }
    exit 0
}

Write-Host ''
$failedActions = @($Script:Actions | Where-Object { $_.level -eq 'ERROR' })
if ($failedActions.Count -gt 0) {
    Write-Host "操作部分完成：$Mode（$($failedActions.Count) 项失败，请查看日志）" -ForegroundColor Yellow
}
else {
    Write-Host "操作完成：$Mode" -ForegroundColor Green
}
Write-Host "操作前备份：$Script:CurrentBackupPath"
Write-Host "动作日志：$Script:ActionLogPath"
if ($Mode -in @('RestoreDirect','SyncApplicationProxy','ClearApplicationProxy')) {
    Write-Host '提示：Codex、终端和其他已运行应用需要重启后，才能读取新的代理环境变量。' -ForegroundColor Yellow
}
if ($failedActions.Count -gt 0) { exit 2 }
