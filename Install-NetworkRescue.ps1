[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Start', 'Stop', 'Status')]
    [string]$Mode = 'Install',
    [string]$InstallDirectory = '',
    [switch]$NoStartup,
    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$defaultInstallDirectory = Join-Path $env:LOCALAPPDATA 'KerryNetworkRescue'
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) { $InstallDirectory = $defaultInstallDirectory }

$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory '断网急救.lnk'
$watcherPath = Join-Path $InstallDirectory 'Watch-NetworkOwnership.ps1'
$dataDirectory = Join-Path $InstallDirectory 'monitor_data'
$stopFlagPath = Join-Path $dataDirectory 'stop.request'

function New-StartupShortcut {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$watcherPath`""
    $shortcut.WorkingDirectory = $InstallDirectory
    $shortcut.Description = '断网急救：监控多代理客户端接管冲突'
    $shortcut.Save()
}

function Test-StartupShortcutTargetsWatcher {
    if (-not (Test-Path -LiteralPath $shortcutPath)) { return $false }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        return ([string]$shortcut.Arguments -like "*$watcherPath*")
    }
    catch { return $false }
}

function Get-RunningMonitorProcesses {
    if (-not (Test-Path -LiteralPath $watcherPath)) { return @() }
    $escapedPath = [regex]::Escape($watcherPath)
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -match $escapedPath })
}

function Stop-RunningMonitor {
    if (-not (Test-Path -LiteralPath $dataDirectory)) { New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null }
    $running = @(Get-RunningMonitorProcesses)
    if ($running.Count -eq 0) { return }

    Set-Content -LiteralPath $stopFlagPath -Value (Get-Date -Format 'o') -Encoding UTF8
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $running = @(Get-RunningMonitorProcesses)
    } while ($running.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($running.Count -gt 0) {
        foreach ($process in $running) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }
}

switch ($Mode) {
    'Install' {
        if (-not (Test-Path -LiteralPath $InstallDirectory)) {
            New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $dataDirectory)) { New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null }
        Stop-RunningMonitor
        $files = @(
            'Scan-NetworkOwnership.ps1', 'Watch-NetworkOwnership.ps1', 'Repair-Network.ps1', 'Test-NetworkPathHealth.ps1',
            'Install-NetworkRescue.ps1', 'Install-NetworkRescueHelper.ps1', 'Invoke-NetworkRescueHelper.ps1',
            'client_adapters.json', 'README.md', '使用说明_先看这里.txt', '更新日志.md', '发布说明_v0.4.1-beta.md',
            'Monitor-LongmaoConnection.ps1',
            '安装断网急救.bat', '启动断网急救.bat', '查看龙猫云断连记录.bat', '卸载断网急救.bat',
            '安装高权限Helper_仅需一次UAC.bat', '卸载高权限Helper.bat'
        )
        foreach ($name in $files) {
            $source = Join-Path $PSScriptRoot $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDirectory $name) -Force }
        }
        $helperSource = Join-Path $PSScriptRoot 'helper'
        $helperTarget = Join-Path $InstallDirectory 'helper'
        if (Test-Path -LiteralPath $helperSource) {
            $resolvedInstall = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') + '\'
            $resolvedHelperTarget = [IO.Path]::GetFullPath($helperTarget)
            if (-not $resolvedHelperTarget.StartsWith($resolvedInstall, [StringComparison]::OrdinalIgnoreCase)) { throw "Helper 目标目录越界：$resolvedHelperTarget" }
            if (Test-Path -LiteralPath $helperTarget) { Remove-Item -LiteralPath $helperTarget -Recurse -Force }
            Copy-Item -LiteralPath $helperSource -Destination $helperTarget -Recurse -Force
        }
        if (Test-Path -LiteralPath $stopFlagPath) { Remove-Item -LiteralPath $stopFlagPath -Force }
        if (-not $NoStartup) { New-StartupShortcut }
        if (-not $NoLaunch) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$watcherPath`"" -WindowStyle Hidden
        }
        Write-Host "断网急救已安装：$InstallDirectory" -ForegroundColor Green
        Write-Host $(if($NoStartup){'开机启动：本次测试跳过'}else{"开机启动项：$shortcutPath"})
        Write-Host $(if($NoLaunch){'托盘监控：本次测试未启动'}else{'托盘监控已启动。'})
    }
    'Uninstall' {
        Stop-RunningMonitor
        if (-not (Test-Path -LiteralPath $stopFlagPath)) { Set-Content -LiteralPath $stopFlagPath -Value (Get-Date -Format 'o') -Encoding UTF8 }
        if (Test-StartupShortcutTargetsWatcher) { Remove-Item -LiteralPath $shortcutPath -Force }
        Write-Host '已移除开机启动项，并通知托盘监控退出。' -ForegroundColor Green
        Write-Host "安装目录、日志和备份仍保留在：$InstallDirectory"
    }
    'Start' {
        if (-not (Test-Path -LiteralPath $watcherPath)) { throw "尚未安装断网急救：$watcherPath" }
        $running = @(Get-RunningMonitorProcesses)
        if ($running.Count -eq 0) {
            if (Test-Path -LiteralPath $stopFlagPath) { Remove-Item -LiteralPath $stopFlagPath -Force }
            Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$watcherPath`"" -WindowStyle Hidden
            Write-Host '断网急救后台监控已启动。' -ForegroundColor Green
        }
        else { Write-Host '断网急救后台监控已经运行。' -ForegroundColor Green }
    }
    'Stop' {
        Stop-RunningMonitor
        Write-Host '断网急救后台监控已停止，开机启动项保持不变。' -ForegroundColor Green
    }
    'Status' {
        $running = @(Get-RunningMonitorProcesses)
        [pscustomobject]@{
            InstallDirectory = $InstallDirectory
            Installed = (Test-Path -LiteralPath $watcherPath)
            StartupShortcut = (Test-StartupShortcutTargetsWatcher)
            StopRequested = (Test-Path -LiteralPath $stopFlagPath)
            Running = ($running.Count -gt 0)
            ProcessIds = @($running | Select-Object -ExpandProperty ProcessId)
        } | Format-List
    }
}
