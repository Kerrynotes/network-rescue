[CmdletBinding()]
param(
    [ValidateSet('Ping','StopServices','StartServices','KillProcesses','CleanupTun','ResetDns','RestoreMachineDirect','SelfTest')]
    [string]$Mode = 'Ping',
    [string[]]$ClientIds = @(),
    [string]$AdapterPath = '',
    [int]$TimeoutMilliseconds = 5000,
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$adapterPathDefault = Join-Path $PSScriptRoot 'client_adapters.json'
if ([string]::IsNullOrWhiteSpace($AdapterPath)) { $AdapterPath = $adapterPathDefault }
if (-not (Test-Path -LiteralPath $AdapterPath)) { throw "未找到客户端适配器白名单：$AdapterPath" }
$adapterList = @(Get-Content -LiteralPath $AdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$allowedIds = @($adapterList | ForEach-Object { [string]$_.id })
foreach ($id in $ClientIds) { if ($allowedIds -notcontains $id) { throw "未授权的客户端 ID：$id" } }
if ($Mode -eq 'SelfTest') {
    $badRejected = $false
    try { & $PSCommandPath -Mode StopServices -ClientIds 'clash_verge;whoami' -TimeoutMilliseconds 1 | Out-Null } catch { $badRejected = $true }
    if (-not $badRejected) { throw '非法客户端 ID 未被拒绝。' }
    Write-Host 'Helper 客户端自检通过：参数白名单正常。' -ForegroundColor Green
    return
}

$pipe = New-Object IO.Pipes.NamedPipeClientStream('.', 'KerryNetworkRescue.Helper.v1', [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Impersonation)
$writer = $null
$reader = $null
try {
    $pipe.Connect($TimeoutMilliseconds)
    $writer = New-Object IO.StreamWriter($pipe, (New-Object Text.UTF8Encoding($false)), 4096, $true)
    $reader = New-Object IO.StreamReader($pipe, (New-Object Text.UTF8Encoding($false)), $false, 4096, $true)
    $writer.AutoFlush = $true
    $request = if ($Mode -eq 'Ping') { 'PING' } else { 'RUN|{0}|{1}' -f $Mode, (($ClientIds | Select-Object -Unique) -join ',') }
    $writer.WriteLine($request)
    $response = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($response)) { throw 'Helper 没有返回响应。' }
    $parts = @($response -split '\|', 3)
    if ($parts[0] -eq 'OK' -and $parts[1] -eq 'PONG') {
        $result = [pscustomobject]@{ success=$true; mode='Ping'; exitCode=0; output='PONG' }
    }
    elseif ($parts[0] -eq 'ERROR') {
        $message = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
        throw "Helper 拒绝请求：$message"
    }
    elseif ($parts[0] -eq 'RESULT' -and $parts.Count -eq 3) {
        $output = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))
        $result = [pscustomobject]@{ success=([int]$parts[1] -eq 0); mode=$Mode; exitCode=[int]$parts[1]; output=$output }
    }
    else { throw "Helper 响应格式无效：$response" }
    if ($PassThru) { return $result }
    if (-not $result.success) { throw "Helper 操作失败（退出码 $($result.exitCode)）：$($result.output)" }
    Write-Host "Helper 操作完成：$Mode" -ForegroundColor Green
    if ($result.output) { Write-Host $result.output }
}
finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $reader) { $reader.Dispose() }
    $pipe.Dispose()
}
