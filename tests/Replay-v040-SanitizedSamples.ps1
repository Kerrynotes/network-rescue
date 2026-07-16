[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scanner = Join-Path $root 'Scan-NetworkOwnership.ps1'
$adapterPath = Join-Path $root 'client_adapters.json'

. $scanner -AdapterPath $adapterPath -SelfTest
$adapters = Get-Adapters
$healthyPath = [pscustomobject]@{
    proxyFailureCandidate = $false
    direct = [pscustomobject]@{ healthy=$true; status='Healthy' }
    proxy = [pscustomobject]@{ healthy=$false; status='NotTested' }
}
$disabledProxy = [pscustomobject]@{ Enabled=$false; Endpoint=$null }
$winHttp = [pscustomobject]@{ Endpoint=$null }

function New-TestProcess {
    param([int]$Id, [string]$Name, [string]$CommandLine)
    return [pscustomobject]@{ Id=$Id; Name=$Name; Path="C:\Test\$Name.exe"; CommandLine=$CommandLine; StartTimeUtc='2026-07-15T00:00:00Z'; SessionId=1 }
}

# 另一台电脑脱敏回放：龙猫核心仍在，但 7890 消失，动态 IPC 12460 无人监听。
$longmaoAdapter = @($adapters | Where-Object { $_.id -eq 'longmao' })
$brokenProcesses = @(
    (New-TestProcess 101 'lmclient' 'C:\Test\lmclient.exe'),
    (New-TestProcess 102 'lmclientCore' 'C:\Test\lmclientCore.exe 12460')
)
$brokenClients = Get-ClientSnapshot -Adapters $longmaoAdapter -Processes $brokenProcesses -Services @([pscustomobject]@{Name='lmclientHelperService';DisplayName='lmclientHelperService';Status='Stopped';StartType='Automatic'}) -Listeners @()
if (-not $brokenClients[0].IpcBroken -or @($brokenClients[0].ControlPorts) -notcontains 12460) { throw '脱敏样本 12460 没有识别为 ClientIpcBroken。' }
$brokenDiagnosis = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients $brokenClients -Listeners @() -PortOwners @() -OwnerIds @() -PathHealth $healthyPath
if ($brokenDiagnosis.code -ne 'ClientIpcBroken') { throw "IPC 失效样本分类错误：$($brokenDiagnosis.code)" }

# 重启后端口变为 13145，并恢复本地监听。
$recoveredProcesses = @(
    (New-TestProcess 111 'lmclient' 'C:\Test\lmclient.exe'),
    (New-TestProcess 112 'lmclientCore' 'C:\Test\lmclientCore.exe 13145')
)
$recoveredListeners = @([pscustomobject]@{Protocol='TCP';Address='127.0.0.1';Port=13145;Pid=111;Process='lmclient'})
$recoveredClients = Get-ClientSnapshot -Adapters $longmaoAdapter -Processes $recoveredProcesses -Services @() -Listeners $recoveredListeners
if ($recoveredClients[0].IpcBroken -or @($recoveredClients[0].ControlPorts) -notcontains 13145) { throw '脱敏样本 13145 恢复状态识别错误。' }

# 龙猫与 V2Cloud 同时存在 UI/Core，必须识别为同源运行时冲突。
$sameFamilyAdapters = @($adapters | Where-Object { $_.id -in @('longmao','v2cloud') })
$sameFamilyProcesses = @(
    (New-TestProcess 201 'lmclient' 'C:\Test\lmclient.exe'),
    (New-TestProcess 202 'lmclientCore' 'C:\Test\lmclientCore.exe 12460'),
    (New-TestProcess 203 'v2cloud' 'C:\Test\v2cloud.exe'),
    (New-TestProcess 204 'v2cloudCore' 'C:\Test\v2cloudCore.exe 12461')
)
$sameFamilyListeners = @(
    [pscustomobject]@{Protocol='TCP';Address='127.0.0.1';Port=12460;Pid=201;Process='lmclient'},
    [pscustomobject]@{Protocol='TCP';Address='127.0.0.1';Port=12461;Pid=203;Process='v2cloud'}
)
$sameFamilyClients = Get-ClientSnapshot -Adapters $sameFamilyAdapters -Processes $sameFamilyProcesses -Services @() -Listeners $sameFamilyListeners
$sharedDiagnosis = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients $sameFamilyClients -Listeners $sameFamilyListeners -PortOwners @() -OwnerIds @() -PathHealth $healthyPath
if ($sharedDiagnosis.code -ne 'SharedRuntimeConflict') { throw "同源运行时样本分类错误：$($sharedDiagnosis.code)" }

# Clash Verge 界面退出，核心仍监听 7890，必须识别为孤儿核心。
$vergeAdapter = @($adapters | Where-Object { $_.id -eq 'clash_verge' })
$vergeProcesses = @((New-TestProcess 301 'verge-mihomo' 'C:\Test\verge-mihomo.exe'))
$vergeListeners = @([pscustomobject]@{Protocol='TCP';Address='127.0.0.1';Port=7890;Pid=301;Process='verge-mihomo'})
$vergeClients = Get-ClientSnapshot -Adapters $vergeAdapter -Processes $vergeProcesses -Services @() -Listeners $vergeListeners
$vergePorts = Get-PortOwnerSnapshot -Clients $vergeClients
$orphanDiagnosis = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients $vergeClients -Listeners $vergeListeners -PortOwners $vergePorts -OwnerIds @() -PathHealth $healthyPath
if ($orphanDiagnosis.code -ne 'OrphanCore') { throw "Clash Verge 孤儿核心样本分类错误：$($orphanDiagnosis.code)" }

# 只有 Helper 服务不构成网络 Owner。
$helperOnly = Get-ClientSnapshot -Adapters $longmaoAdapter -Processes @((New-TestProcess 401 'lmclientHelperService' 'C:\Test\lmclientHelperService.exe')) -Services @([pscustomobject]@{Name='lmclientHelperService';DisplayName='lmclientHelperService';Status='Running';StartType='Automatic'}) -Listeners @()
if ($helperOnly[0].HasCoreEvidence) { throw 'Helper-only 被误判为核心证据。' }
$helperDiagnosis = Get-DiagnosisSnapshot -SystemProxy $disabledProxy -SystemProxyOwner $null -TunOwners @() -WinHttp $winHttp -WinHttpOwner $null -EnvironmentProxies @() -EnvironmentOwners @() -Clients $helperOnly -Listeners @() -PortOwners @() -OwnerIds @() -PathHealth $healthyPath
if ($helperDiagnosis.code -ne 'HealthyDirect') { throw "Helper-only 被误判为网络 Owner：$($helperDiagnosis.code)" }

Write-Host 'v0.4.0-beta 脱敏样本回放通过：12460 失效、13145 恢复、同源冲突、孤儿核心和 Helper-only 边界均正确。' -ForegroundColor Green
