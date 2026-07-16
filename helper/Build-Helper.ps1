[CmdletBinding()]
param([string]$OutputDirectory = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot 'bin' }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

$source = Join-Path $PSScriptRoot 'NetworkRescueHelperService.cs'
$output = Join-Path $OutputDirectory 'NetworkRescueHelperService.exe'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { $csc = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path -LiteralPath $csc)) { throw '未找到 .NET Framework C# 编译器。' }

& $csc /nologo /target:exe /platform:anycpu /optimize+ /out:"$output" `
    /reference:System.ServiceProcess.dll /reference:System.Core.dll /reference:System.Security.dll "$source"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw "Helper 编译失败，退出码：$LASTEXITCODE" }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Privileged-Repair.ps1') -Destination (Join-Path $OutputDirectory 'Privileged-Repair.ps1') -Force
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'client_adapters.json') -Destination (Join-Path $OutputDirectory 'client_adapters.json') -Force
& $output --selftest
if ($LASTEXITCODE -ne 0) { throw 'Helper 编译后自检失败。' }
Write-Host "Helper 已编译：$output" -ForegroundColor Green
