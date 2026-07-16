[CmdletBinding()]
param(
    [string]$ProxyEndpoint = '',
    [string]$EnvironmentProxyEndpoint = '',
    [ValidateRange(2, 30)]
    [int]$TimeoutSeconds = 6,
    [switch]$SkipDirect,
    [switch]$SkipProxy,
    [switch]$SelfTest,
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Script:Version = '0.4.0-beta'

$Script:DirectTargets = @(
    'http://www.msftconnecttest.com/connecttest.txt',
    'https://www.baidu.com/'
)
$Script:ProxyTargets = @(
    'https://www.gstatic.com/generate_204',
    'https://cp.cloudflare.com/generate_204',
    'https://www.msftconnecttest.com/connecttest.txt'
)

function ConvertTo-LocalProxyUri {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match($Value, '(?i)(?:https?=|socks=)?(?:https?://|socks5?://)?(?<host>127\.0\.0\.1|localhost|\[::1\]|::1)\s*:\s*(?<port>\d{1,5})')
    if (-not $match.Success) { return $null }
    $port = [int]$match.Groups['port'].Value
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    return [pscustomobject]@{
        Host = '127.0.0.1'
        Port = $port
        Text = "127.0.0.1:$port"
        Uri = "http://127.0.0.1:$port"
    }
}

function Get-ProbeGroupStatus {
    param([int]$SuccessCount, [int]$TotalCount, [int]$RequiredSuccesses)
    if ($TotalCount -eq 0) { return 'NotTested' }
    if ($SuccessCount -ge $RequiredSuccesses) { return 'Healthy' }
    if ($SuccessCount -gt 0) { return 'Degraded' }
    return 'Failed'
}

function Start-HttpProbe {
    param([string]$Url, [string]$ProxyUri, [bool]$UseProxy)
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $UseProxy
    if ($UseProxy) {
        $handler.Proxy = New-Object System.Net.WebProxy($ProxyUri, $true)
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $started = [DateTime]::UtcNow
    $task = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    return [pscustomobject]@{
        Url = $Url
        Client = $client
        Handler = $handler
        Task = $task
        StartedUtc = $started
    }
}

function Complete-HttpProbe {
    param($Probe)
    $statusCode = 0
    $success = $false
    $errorText = ''
    try {
        $response = $Probe.Task.GetAwaiter().GetResult()
        try {
            $statusCode = [int]$response.StatusCode
            $success = ($statusCode -ge 200 -and $statusCode -lt 500)
        }
        finally { $response.Dispose() }
    }
    catch {
        $errorText = [string]$_.Exception.GetBaseException().Message
        if ($errorText.Length -gt 240) { $errorText = $errorText.Substring(0, 240) }
    }
    finally {
        $Probe.Client.Dispose()
        $Probe.Handler.Dispose()
    }
    return [pscustomobject]@{
        url = [string]$Probe.Url
        host = ([Uri]$Probe.Url).Host
        success = $success
        statusCode = $statusCode
        elapsedMs = [int]([DateTime]::UtcNow - $Probe.StartedUtc).TotalMilliseconds
        error = $errorText
    }
}

function Invoke-HttpProbeGroup {
    param([string[]]$Targets, [string]$ProxyUri = '', [bool]$UseProxy = $false, [int]$RequiredSuccesses = 1)
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($url in $Targets) { $pending.Add((Start-HttpProbe -Url $url -ProxyUri $ProxyUri -UseProxy $UseProxy)) }
    $results = New-Object System.Collections.Generic.List[object]
    $successCount = 0
    for ($index = 0; $index -lt $pending.Count; $index++) {
        $probe = $pending[$index]
        $completed = Complete-HttpProbe -Probe $probe
        $results.Add($completed)
        if ($completed.success) { $successCount++ }
        if ($successCount -ge $RequiredSuccesses) {
            for ($remainingIndex = $index + 1; $remainingIndex -lt $pending.Count; $remainingIndex++) {
                $remaining = $pending[$remainingIndex]
                try { $remaining.Client.CancelPendingRequests() } catch {}
                try { $remaining.Client.Dispose() } catch {}
                try { $remaining.Handler.Dispose() } catch {}
                $results.Add([pscustomobject]@{
                    url=[string]$remaining.Url; host=([Uri]$remaining.Url).Host; success=$false
                    statusCode=0; elapsedMs=0; error='已达到多目标成功阈值，停止多余探测'
                })
            }
            break
        }
    }
    return [pscustomobject]@{
        status = Get-ProbeGroupStatus -SuccessCount $successCount -TotalCount $results.Count -RequiredSuccesses $RequiredSuccesses
        successCount = $successCount
        requiredSuccesses = $RequiredSuccesses
        totalCount = $results.Count
        results = $results.ToArray()
    }
}

function Invoke-DnsProbeGroup {
    $hosts = @($Script:DirectTargets + $Script:ProxyTargets | ForEach-Object { ([Uri]$_).Host } | Select-Object -Unique)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($hostName in $hosts) {
        $success = $false
        $addresses = @()
        $errorText = ''
        try {
            $task = [Net.Dns]::GetHostAddressesAsync($hostName)
            if (-not $task.Wait($TimeoutSeconds * 1000)) { throw 'DNS 查询超时' }
            $addresses = @($task.Result | ForEach-Object { $_.ToString() })
            $success = ($addresses.Count -gt 0)
        }
        catch { $errorText = [string]$_.Exception.GetBaseException().Message }
        $rows.Add([pscustomobject]@{ host=$hostName; success=$success; addressCount=$addresses.Count; error=$errorText })
    }
    $successCount = @($rows | Where-Object { $_.success }).Count
    return [pscustomobject]@{
        status = Get-ProbeGroupStatus -SuccessCount $successCount -TotalCount $rows.Count -RequiredSuccesses 2
        successCount = $successCount
        requiredSuccesses = 2
        totalCount = $rows.Count
        results = $rows.ToArray()
    }
}

function Get-SystemProxyEndpoint {
    try {
        $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$item.ProxyEnable -ne 1) { return '' }
        return [string]$item.ProxyServer
    }
    catch { return '' }
}

function Test-LocalListener {
    param($Endpoint)
    if ($null -eq $Endpoint) { return [pscustomobject]@{ listening=$false; pid=0; process='' } }
    $connection = Get-NetTCPConnection -State Listen -LocalPort $Endpoint.Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $connection) { return [pscustomobject]@{ listening=$false; pid=0; process='' } }
    $processName = ''
    try { $processName = (Get-Process -Id ([int]$connection.OwningProcess) -ErrorAction Stop).ProcessName } catch {}
    return [pscustomobject]@{ listening=$true; pid=[int]$connection.OwningProcess; process=[string]$processName }
}

function Invoke-PathHealthSelfTest {
    $endpoint = ConvertTo-LocalProxyUri 'http=127.0.0.1:7890;https=127.0.0.1:7890'
    if ($null -eq $endpoint -or $endpoint.Port -ne 7890) { throw '本地代理端点解析失败。' }
    if ($null -ne (ConvertTo-LocalProxyUri 'https://proxy.example.com:443')) { throw '远程代理被误判为本地代理。' }
    if ((Get-ProbeGroupStatus 2 3 2) -ne 'Healthy') { throw '健康阈值判定失败。' }
    if ((Get-ProbeGroupStatus 1 3 2) -ne 'Degraded') { throw '降级阈值判定失败。' }
    if ((Get-ProbeGroupStatus 0 3 2) -ne 'Failed') { throw '失败阈值判定失败。' }
    Write-Host '联网路径探测自检通过：端点解析和多目标阈值正常。' -ForegroundColor Green
}

if ($SelfTest) { Invoke-PathHealthSelfTest; return }
if ([string]::IsNullOrWhiteSpace($ProxyEndpoint)) { $ProxyEndpoint = Get-SystemProxyEndpoint }

$proxy = ConvertTo-LocalProxyUri $ProxyEndpoint
$environmentProxy = ConvertTo-LocalProxyUri $EnvironmentProxyEndpoint
$localListener = Test-LocalListener -Endpoint $proxy
$directResult = if ($SkipDirect) {
    [pscustomobject]@{ status='NotTested'; successCount=0; requiredSuccesses=1; totalCount=0; results=@() }
} else {
    Invoke-HttpProbeGroup -Targets $Script:DirectTargets -UseProxy $false -RequiredSuccesses 1
}
$proxyResult = if ($SkipProxy -or $null -eq $proxy -or -not $localListener.listening) {
    [pscustomobject]@{ status='NotTested'; successCount=0; requiredSuccesses=2; totalCount=0; results=@() }
} else {
    Invoke-HttpProbeGroup -Targets $Script:ProxyTargets -ProxyUri $proxy.Uri -UseProxy $true -RequiredSuccesses 2
}
$environmentResult = if ($SkipProxy -or $null -eq $environmentProxy) {
    [pscustomobject]@{ status='NotTested'; successCount=0; requiredSuccesses=2; totalCount=0; results=@() }
} elseif ($null -ne $proxy -and $environmentProxy.Text -eq $proxy.Text) {
    $proxyResult
} else {
    $environmentListener = Test-LocalListener -Endpoint $environmentProxy
    if (-not $environmentListener.listening) {
        [pscustomobject]@{ status='Failed'; successCount=0; requiredSuccesses=2; totalCount=0; results=@(); reason='本地端口无人监听' }
    } else {
        Invoke-HttpProbeGroup -Targets $Script:ProxyTargets -ProxyUri $environmentProxy.Uri -UseProxy $true -RequiredSuccesses 2
    }
}
$dnsResult = Invoke-DnsProbeGroup

$result = [pscustomobject][ordered]@{
    schemaVersion = 2
    version = $Script:Version
    testedAt = (Get-Date).ToString('o')
    direct = [pscustomobject]@{
        meaning = '绕过 Windows 系统代理；若已开启 TUN，流量仍可能经过 TUN。'
        status = $directResult.status
        healthy = ($directResult.status -eq 'Healthy')
        successCount = $directResult.successCount
        requiredSuccesses = $directResult.requiredSuccesses
        totalCount = $directResult.totalCount
        results = @($directResult.results)
    }
    proxy = [pscustomobject]@{
        endpoint = if ($null -ne $proxy) { $proxy.Text } else { '' }
        configured = ($null -ne $proxy)
        listening = [bool]$localListener.listening
        pid = [int]$localListener.pid
        process = [string]$localListener.process
        status = $proxyResult.status
        healthy = ($proxyResult.status -eq 'Healthy')
        successCount = $proxyResult.successCount
        requiredSuccesses = $proxyResult.requiredSuccesses
        totalCount = $proxyResult.totalCount
        results = @($proxyResult.results)
    }
    environmentProxy = [pscustomobject]@{
        endpoint = if ($null -ne $environmentProxy) { $environmentProxy.Text } else { '' }
        configured = ($null -ne $environmentProxy)
        status = $environmentResult.status
        healthy = ($environmentResult.status -eq 'Healthy')
        successCount = $environmentResult.successCount
        requiredSuccesses = $environmentResult.requiredSuccesses
        totalCount = $environmentResult.totalCount
        results = @($environmentResult.results)
    }
    dns = $dnsResult
    proxyFailureCandidate = (
        $null -ne $proxy -and $localListener.listening -and
        $proxyResult.status -in @('Failed','Degraded') -and
        $directResult.status -eq 'Healthy'
    )
}

if ($PassThru) { return $result }
$result | Format-List
