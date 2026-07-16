[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall','Start','Stop','Status','SelfTest')]
    [string]$Mode = 'Install',
    [switch]$AutoElevate,
    [string]$ResultPath = '',
    [string]$UserSid = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$serviceName = 'KerryNetworkRescueHelper'
$installDirectory = Join-Path $env:ProgramFiles 'KerryNetworkRescueHelper'
$sourceDirectory = Join-Path $PSScriptRoot 'helper'
$binarySource = Join-Path $sourceDirectory 'bin\NetworkRescueHelperService.exe'
$binaryTarget = Join-Path $installDirectory 'NetworkRescueHelperService.exe'
$Script:InstallStage = '准备安装'

function Write-HelperInstallResult {
    param([bool]$Success, [string]$Stage, [string]$Message)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $parent = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            schemaVersion = 1
            observedAt = (Get-Date).ToString('o')
            success = $Success
            stage = $Stage
            message = $Message
            serviceInstalled = ($null -ne $service)
            serviceStatus = $(if ($service) { [string]$service.Status } else { 'NotInstalled' })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
    catch {
        # 结果文件只用于诊断，不允许覆盖原始安装错误。
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $arguments += " -ResultPath `"$ResultPath`"" }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments += " -UserSid `"$sid`""
    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
    catch {
        Write-HelperInstallResult -Success $false -Stage '等待 UAC' -Message '管理员授权窗口被取消、关闭或未能启动。'
        Write-Error '管理员授权窗口被取消、关闭或未能启动。'
        exit 1223
    }
}

if ($Mode -eq 'SelfTest') {
    & (Join-Path $sourceDirectory 'Build-Helper.ps1')
    & (Join-Path $PSScriptRoot 'Invoke-NetworkRescueHelper.ps1') -Mode SelfTest
    Write-Host 'Helper 安装组件自检通过。' -ForegroundColor Green
    return
}

if ($Mode -eq 'Status') {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $ping = $false
    if ($null -ne $service -and $service.Status -eq 'Running') {
        try { $ping = (& (Join-Path $PSScriptRoot 'Invoke-NetworkRescueHelper.ps1') -Mode Ping -PassThru).success } catch { $ping = $false }
    }
    [pscustomobject]@{ Installed=($null-ne$service); Status=$(if($service){$service.Status}else{'NotInstalled'}); InstallDirectory=$installDirectory; Ping=$ping } | Format-List
    return
}

if ($Mode -in @('Install','Uninstall') -and -not (Test-IsAdministrator)) {
    if ($AutoElevate) { Start-ElevatedSelf }
    Write-HelperInstallResult -Success $false -Stage '检查权限' -Message '当前进程没有管理员权限。'
    throw '安装或卸载 Helper 需要管理员权限。请使用 -AutoElevate；安装时只需确认一次 UAC。'
}

try {
    switch ($Mode) {
      'Install' {
        $Script:InstallStage = '准备 Helper 文件'
        if (-not (Test-Path -LiteralPath $binarySource)) { & (Join-Path $sourceDirectory 'Build-Helper.ps1') }
        $Script:InstallStage = '清理旧 Helper 服务'
        $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            if ($existing.Status -ne 'Stopped') {
                Stop-Service $serviceName -Force
                $existing.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
            }
            & sc.exe delete $serviceName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "删除旧 Helper 服务失败：$LASTEXITCODE" }
            $deadline = (Get-Date).AddSeconds(15)
            while ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                if ((Get-Date) -ge $deadline) { throw '等待旧 Helper 服务删除超时。' }
                Start-Sleep -Milliseconds 250
            }
        }
        $Script:InstallStage = '复制 Helper 文件'
        if (-not (Test-Path -LiteralPath $installDirectory)) { New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null }
        Copy-Item -LiteralPath $binarySource -Destination $binaryTarget -Force
        Copy-Item -LiteralPath (Join-Path $sourceDirectory 'Privileged-Repair.ps1') -Destination (Join-Path $installDirectory 'Privileged-Repair.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'client_adapters.json') -Destination (Join-Path $installDirectory 'client_adapters.json') -Force
        & icacls.exe $installDirectory /inheritance:e /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        $sid = if ([string]::IsNullOrWhiteSpace($UserSid)) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { $UserSid }
        if ($sid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$') { throw '请求安装 Helper 的用户 SID 格式无效。' }
        $Script:InstallStage = '创建 Helper 服务'
        $binPath = '"{0}" --sid {1}' -f $binaryTarget, $sid
        # sc.exe 经过 Windows PowerShell 5.1 的原生命令参数转换时，会丢失
        # Program Files 路径外层的引号，并以 1639 拒绝包含启动参数的 binPath。
        # Win32_Service.Create 直接接收完整字符串，可避免命令行二次拆分。
        $createResult = Invoke-CimMethod -ClassName Win32_Service -MethodName Create -Arguments @{
            Name = $serviceName
            DisplayName = '断网急救 Helper'
            PathName = $binPath
            ServiceType = [uint32]16
            ErrorControl = [uint32]1
            StartMode = 'Automatic'
            DesktopInteract = $false
            StartName = 'LocalSystem'
        }
        if ([int]$createResult.ReturnValue -ne 0) { throw "创建 Helper 服务失败，Win32_Service 返回码：$($createResult.ReturnValue)" }
        & sc.exe description $serviceName '为断网急救执行白名单内的服务、进程、TUN 和 DNS 高权限操作。' | Out-Null
        & sc.exe failure $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/15000/none/0' | Out-Null
        $serviceSddl = ((& sc.exe sdshow $serviceName 2>&1) | Where-Object { $_ -match '^D:' } | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($serviceSddl)) { throw '读取 Helper 服务权限失败。' }
        $serviceSddl = $serviceSddl.Trim()
        $userAce = "(A;;CCLCSWRPWPLOCRRC;;;$sid)"
        if ($serviceSddl -notlike "*$userAce*") {
            $saclIndex = $serviceSddl.IndexOf('S:')
            $serviceSddl = if ($saclIndex -ge 0) { $serviceSddl.Insert($saclIndex, $userAce) } else { $serviceSddl + $userAce }
            & sc.exe sdset $serviceName $serviceSddl | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "设置 Helper 启停权限失败：$LASTEXITCODE" }
        }
        $Script:InstallStage = '启动并验证 Helper 服务'
        Start-Service $serviceName
        (Get-Service $serviceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
        $ping = & (Join-Path $PSScriptRoot 'Invoke-NetworkRescueHelper.ps1') -Mode Ping -TimeoutMilliseconds 3000 -PassThru
        if ($null -eq $ping -or -not [bool]$ping.success) { throw 'Helper 服务已经启动，但通信验证失败。' }
        Write-HelperInstallResult -Success $true -Stage '安装完成' -Message 'Helper 已安装、启动并通过通信验证。'
        Write-Host '断网急救 Helper 已安装并启动；后续白名单修复不再逐次弹 UAC。' -ForegroundColor Green
      }
      'Uninstall' {
        $Script:InstallStage = '卸载 Helper 服务'
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service) { if ($service.Status -ne 'Stopped') { Stop-Service $serviceName -Force; $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15)) }; & sc.exe delete $serviceName | Out-Null }
        Write-HelperInstallResult -Success $true -Stage '卸载完成' -Message 'Helper 服务已卸载。'
        Write-Host '断网急救 Helper 服务已卸载。日志保留在 ProgramData。' -ForegroundColor Green
      }
      'Start' {
        $Script:InstallStage = '启动 Helper 服务'
        try { Start-Service $serviceName -ErrorAction Stop; (Get-Service $serviceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(15)); Write-Host 'Helper 已启动。' -ForegroundColor Green }
        catch { if ($AutoElevate -and -not (Test-IsAdministrator)) { Start-ElevatedSelf }; throw "启动 Helper 失败：$($_.Exception.Message)" }
      }
      'Stop' {
        $Script:InstallStage = '停止 Helper 服务'
        try { Stop-Service $serviceName -Force -ErrorAction Stop; (Get-Service $serviceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15)); Write-Host 'Helper 已停止。' -ForegroundColor Green }
        catch { if ($AutoElevate -and -not (Test-IsAdministrator)) { Start-ElevatedSelf }; throw "停止 Helper 失败：$($_.Exception.Message)" }
      }
    }
}
catch {
    Write-HelperInstallResult -Success $false -Stage $Script:InstallStage -Message $_.Exception.Message
    throw
}
