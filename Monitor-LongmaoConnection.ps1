[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$ProxyPort = 0,
    [ValidateRange(1, 300)]
    [int]$IntervalSeconds = 5,
    [ValidateRange(1, 20)]
    [int]$FailureThreshold = 3,
    [ValidateRange(1, 20)]
    [int]$RecoveryThreshold = 2,
    [ValidateRange(2, 60)]
    [int]$ProbeTimeoutSeconds = 8,
    [string]$ProbeUrl = 'https://www.gstatic.com/generate_204',
    [string]$PathHealthScript = '',
    [string]$DataDirectory = '',
    [switch]$SkipProbe,
    [switch]$Once,
    [switch]$Console,
    [switch]$Stop,
    [switch]$OpenLog,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Version = '0.4.0-beta'
$Script:CoreProcessPattern = '^lmclientCore$'
$Script:KnownProxyPorts = @(7890, 7892)
$Script:LastDetectedProxyPort = 0

if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
    $DataDirectory = Join-Path $PSScriptRoot 'monitor_data\longmao_connection'
}
if ([string]::IsNullOrWhiteSpace($PathHealthScript)) {
    $PathHealthScript = Join-Path $PSScriptRoot 'Test-NetworkPathHealth.ps1'
}

$Script:LogPath = Join-Path $DataDirectory '龙猫云断连监控.log'
$Script:EventCsvPath = Join-Path $DataDirectory '龙猫云断连记录.csv'
$Script:LatestStatePath = Join-Path $DataDirectory '龙猫云当前状态.json'
$Script:StopFlagPath = Join-Path $DataDirectory 'stop.request'
$Script:LogMaxBytes = 2MB
$Script:LogArchiveCount = 3
$Script:EventRetentionDays = 180
$Script:EventMaxRecords = 5000

function Initialize-DataDirectory {
    if (-not (Test-Path -LiteralPath $DataDirectory)) {
        New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    }
}

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
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force -ErrorAction Stop }
    for ($index = $ArchiveCount - 1; $index -ge 1; $index--) {
        $source = "$Path.$index"
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination "$Path.$($index + 1)" -Force -ErrorAction Stop
        }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop
}

function Limit-EventHistory {
    param(
        [string]$Path,
        [int]$RetentionDays,
        [int]$MaxRecords
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $temporaryPath = "$Path.trim-$PID.tmp"
    try {
        $rows = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        $retained = @($rows | Where-Object {
            try {
                [datetime]::ParseExact([string]$_.'记录时间', 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) -ge $cutoff
            }
            catch { $true }
        } | Select-Object -Last $MaxRecords)
        if ($retained.Count -eq $rows.Count) { return $true }
        if ($retained.Count -gt 0) {
            $retained | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding UTF8
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }
        else {
            Remove-Item -LiteralPath $Path -Force
        }
        return $true
    }
    catch { return $false }
    finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

function Write-MonitorLog {
    param(
        [string]$Level,
        [string]$Message
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $incomingBytes = [Text.Encoding]::UTF8.GetByteCount($line + [Environment]::NewLine)
    Invoke-FileRotation -Path $Script:LogPath -MaxBytes $Script:LogMaxBytes -ArchiveCount $Script:LogArchiveCount -IncomingBytes $incomingBytes
    Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8
    if ($Console) { Write-Host $line }
}

function Get-ProcessNameSafe {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [string]$process.ProcessName
    }
    catch {
        return '未知进程'
    }
}

function Get-PortListeners {
    param([int]$Port)

    $rows = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)) {
            $rows.Add([pscustomobject]@{
                Address = [string]$item.LocalAddress
                Port = [int]$item.LocalPort
                Pid = [int]$item.OwningProcess
                Process = Get-ProcessNameSafe -ProcessId ([int]$item.OwningProcess)
            })
        }
        return $rows.ToArray()
    }
    catch {
        foreach ($line in @(& netstat.exe -ano -p tcp 2>$null)) {
            if ($line -notmatch '^\s*TCP\s+(?<endpoint>\S+)\s+\S+\s+LISTENING\s+(?<pid>\d+)') { continue }
            $endpoint = [string]$Matches.endpoint
            if ($endpoint -notmatch ":$Port$") { continue }
            $pidValue = [int]$Matches.pid
            $address = $endpoint.Substring(0, $endpoint.Length - (":$Port").Length).Trim('[', ']')
            $rows.Add([pscustomobject]@{
                Address = $address
                Port = $Port
                Pid = $pidValue
                Process = Get-ProcessNameSafe -ProcessId $pidValue
            })
        }
        return $rows.ToArray()
    }
}

function Get-SystemProxyPort {
    try {
        $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$item.ProxyEnable -ne 1) { return 0 }
        $match = [regex]::Match([string]$item.ProxyServer, '(?i)(?:https?=|socks=)?(?:https?://|socks5?://)?(?:127\.0\.0\.1|localhost|\[::1\]|::1)\s*:\s*(?<port>\d{1,5})')
        if (-not $match.Success) { return 0 }
        $port = [int]$match.Groups['port'].Value
        if ($port -lt 1 -or $port -gt 65535) { return 0 }
        return $port
    }
    catch { return 0 }
}

function Select-LongmaoProxyPort {
    param(
        [object[]]$Listeners,
        [int]$SystemProxyPort,
        [int]$PreviousPort
    )
    $dragonListeners = @($Listeners | Where-Object { [string]$_.Process -match $Script:CoreProcessPattern })
    if ($SystemProxyPort -gt 0 -and @($dragonListeners | Where-Object { [int]$_.Port -eq $SystemProxyPort }).Count -gt 0) { return $SystemProxyPort }
    if ($PreviousPort -gt 0 -and @($dragonListeners | Where-Object { [int]$_.Port -eq $PreviousPort }).Count -gt 0) { return $PreviousPort }
    foreach ($knownPort in $Script:KnownProxyPorts) {
        if (@($dragonListeners | Where-Object { [int]$_.Port -eq $knownPort }).Count -gt 0) { return [int]$knownPort }
    }
    $first = $dragonListeners | Select-Object -First 1
    if ($null -ne $first) { return [int]$first.Port }
    return 0
}

function Resolve-LongmaoProxyTarget {
    if ($ProxyPort -gt 0) {
        return [pscustomobject]@{ Port=$ProxyPort; Listeners=@(Get-PortListeners -Port $ProxyPort); Mode='Fixed' }
    }

    $systemProxyPort = Get-SystemProxyPort
    $candidatePorts = @($Script:KnownProxyPorts + @($systemProxyPort) | Where-Object { [int]$_ -gt 0 } | Select-Object -Unique)
    $allListeners = New-Object System.Collections.Generic.List[object]
    foreach ($candidatePort in $candidatePorts) {
        foreach ($listener in @(Get-PortListeners -Port ([int]$candidatePort))) { $allListeners.Add($listener) }
    }
    $selectedPort = Select-LongmaoProxyPort -Listeners $allListeners.ToArray() -SystemProxyPort $systemProxyPort -PreviousPort $Script:LastDetectedProxyPort
    $selectedListeners = if ($selectedPort -gt 0) { @($allListeners | Where-Object { [int]$_.Port -eq $selectedPort }) } else { @() }
    return [pscustomobject]@{ Port=$selectedPort; Listeners=$selectedListeners; Mode='Auto' }
}

function Test-ProxyConnectivity {
    param(
        [int]$Port,
        [string]$Url
    )

    if ($SkipProbe) {
        return [pscustomobject]@{ Success = $true; Detail = '已按参数跳过实际代理联网检测'; HttpCode = '' }
    }

    if (-not (Test-Path -LiteralPath $PathHealthScript)) {
        return [pscustomobject]@{ Success = $false; Detail = '通用联网路径探测组件不存在'; HttpCode = '' }
    }

    try {
        $output = & $PathHealthScript -ProxyEndpoint "127.0.0.1:$Port" -TimeoutSeconds $ProbeTimeoutSeconds -SkipDirect -PassThru
        $health = @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'schemaVersion' }) | Select-Object -Last 1
        if ($null -eq $health) { throw '探测组件没有返回结构化结果' }
        $success = [bool]$health.proxy.healthy
        $httpCode = @($health.proxy.results | Where-Object { $_.statusCode -gt 0 } | Select-Object -ExpandProperty statusCode) -join ','
        $detail = if ($success) {
            "多目标代理联网正常，成功 $($health.proxy.successCount)/$($health.proxy.totalCount)"
        } else {
            "多目标代理联网失败，成功 $($health.proxy.successCount)/$($health.proxy.totalCount)"
        }
        return [pscustomobject]@{ Success = $success; Detail = $detail; HttpCode = $httpCode }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Detail = "代理联网检测异常：$($_.Exception.Message)"; HttpCode = '' }
    }
}

function Get-ListenerSummary {
    param([object[]]$Listeners)
    if (@($Listeners).Count -eq 0) { return '无' }
    return (@($Listeners | ForEach-Object { "$($_.Process)(PID $($_.Pid))" } | Select-Object -Unique) -join '、')
}

function Get-ConnectionAssessment {
    param(
        [bool]$CoreRunning,
        [object[]]$Listeners,
        [bool]$ProbeSuccess,
        [string]$ProbeDetail,
        [int]$Port
    )

    if (-not $CoreRunning) {
        return [pscustomobject]@{ IsConnected = $false; Reason = '龙猫云核心 lmclientCore 未运行' }
    }

    if ($Port -le 0) {
        return [pscustomobject]@{ IsConnected = $false; Reason = '龙猫云核心正在运行，但未发现由它监听的本地代理端口' }
    }

    if (@($Listeners).Count -eq 0) {
        return [pscustomobject]@{ IsConnected = $false; Reason = "龙猫云核心正在运行，但端口 $Port 没有监听者" }
    }

    $dragonListeners = @($Listeners | Where-Object { [string]$_.Process -match $Script:CoreProcessPattern })
    if ($dragonListeners.Count -eq 0) {
        return [pscustomobject]@{
            IsConnected = $false
            Reason = "端口 $Port 被其他程序占用：$(Get-ListenerSummary -Listeners $Listeners)"
        }
    }

    $otherListeners = @($Listeners | Where-Object { [string]$_.Process -notmatch $Script:CoreProcessPattern })
    if ($otherListeners.Count -gt 0) {
        return [pscustomobject]@{
            IsConnected = $false
            Reason = "端口 $Port 存在多个监听者：$(Get-ListenerSummary -Listeners $Listeners)"
        }
    }

    if (-not $ProbeSuccess) {
        return [pscustomobject]@{
            IsConnected = $false
            Reason = "龙猫云已监听端口 $Port，但$ProbeDetail"
        }
    }

    return [pscustomobject]@{ IsConnected = $true; Reason = "龙猫云连接正常：$ProbeDetail" }
}

function Get-LiveSample {
    $checkedAt = Get-Date
    $coreProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $Script:CoreProcessPattern })
    $target = Resolve-LongmaoProxyTarget
    $effectivePort = [int]$target.Port
    $listeners = @($target.Listeners)
    if ($ProxyPort -eq 0 -and $effectivePort -gt 0 -and $effectivePort -ne $Script:LastDetectedProxyPort) {
        $changeText = if ($Script:LastDetectedProxyPort -gt 0) { "$($Script:LastDetectedProxyPort) → $effectivePort" } else { "$effectivePort" }
        Write-MonitorLog -Level 'INFO' -Message "自动识别到龙猫云代理端口：$changeText。"
        $Script:LastDetectedProxyPort = $effectivePort
    }
    $hasDragonListener = @($listeners | Where-Object { [string]$_.Process -match $Script:CoreProcessPattern }).Count -gt 0
    $probe = if ($hasDragonListener) {
        Test-ProxyConnectivity -Port $effectivePort -Url $ProbeUrl
    }
    else {
        [pscustomobject]@{ Success = $false; Detail = '尚未由龙猫云监听，不执行外网探测'; HttpCode = '' }
    }
    $assessment = Get-ConnectionAssessment -CoreRunning ($coreProcesses.Count -gt 0) -Listeners $listeners `
        -ProbeSuccess ([bool]$probe.Success) -ProbeDetail ([string]$probe.Detail) -Port $effectivePort

    return [pscustomobject][ordered]@{
        CheckedAt = $checkedAt.ToString('o')
        IsConnected = [bool]$assessment.IsConnected
        Reason = [string]$assessment.Reason
        ProxyPort = $effectivePort
        ProxyPortMode = [string]$target.Mode
        CorePids = @($coreProcesses | ForEach-Object { [int]$_.Id })
        Listeners = @($listeners)
        ProbeUrl = $ProbeUrl
        ProbeSuccess = [bool]$probe.Success
        ProbeHttpCode = [string]$probe.HttpCode
    }
}

function New-RuntimeState {
    return [pscustomobject][ordered]@{
        Status = 'Unknown'
        DisconnectStart = ''
        PendingFailureStart = ''
        PendingRecoveryStart = ''
        ConsecutiveFailures = 0
        ConsecutiveSuccesses = 0
    }
}

function Get-RuntimeState {
    $state = New-RuntimeState
    if (-not (Test-Path -LiteralPath $Script:LatestStatePath)) { return $state }
    try {
        $saved = Get-Content -LiteralPath $Script:LatestStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('Status', 'DisconnectStart', 'PendingFailureStart', 'PendingRecoveryStart', 'ConsecutiveFailures', 'ConsecutiveSuccesses')) {
            if ($saved.PSObject.Properties.Name -contains $name) { $state.$name = $saved.$name }
        }
    }
    catch {
        Write-MonitorLog -Level 'WARN' -Message "无法读取上次监控状态，将重新开始：$($_.Exception.Message)"
    }
    return $state
}

function Write-EventRecord {
    param(
        [string]$EventType,
        [string]$DisconnectStart,
        [string]$RecoveryTime,
        [double]$DurationSeconds,
        $Sample
    )

    $record = [pscustomobject][ordered]@{
        '记录时间' = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        '事件类型' = $EventType
        '断连开始时间' = $DisconnectStart
        '恢复时间' = $RecoveryTime
        '断连持续秒数' = if ($DurationSeconds -ge 0) { [math]::Round($DurationSeconds, 1) } else { '' }
        '原因' = [string]$Sample.Reason
        '代理端口' = [int]$Sample.ProxyPort
        '端口监听者' = Get-ListenerSummary -Listeners @($Sample.Listeners)
        '核心PID' = (@($Sample.CorePids) -join '、')
    }
    $record | Export-Csv -LiteralPath $Script:EventCsvPath -NoTypeInformation -Append -Encoding UTF8
    if (-not (Limit-EventHistory -Path $Script:EventCsvPath -RetentionDays $Script:EventRetentionDays -MaxRecords $Script:EventMaxRecords)) {
        Write-MonitorLog -Level 'WARN' -Message '断连记录超限清理失败，将在下次记录时重试。'
    }
}

function Save-LatestState {
    param($State, $Sample)
    $latest = [pscustomobject][ordered]@{
        Version = $Script:Version
        Status = [string]$State.Status
        StatusText = switch ([string]$State.Status) {
            'Connected' { '已连接' }
            'Disconnected' { '已断连' }
            default { '检测中' }
        }
        DisconnectStart = [string]$State.DisconnectStart
        PendingFailureStart = [string]$State.PendingFailureStart
        PendingRecoveryStart = [string]$State.PendingRecoveryStart
        ConsecutiveFailures = [int]$State.ConsecutiveFailures
        ConsecutiveSuccesses = [int]$State.ConsecutiveSuccesses
        LastCheckAt = [string]$Sample.CheckedAt
        LastReason = [string]$Sample.Reason
        ProxyPort = [int]$Sample.ProxyPort
        ProxyPortMode = [string]$Sample.ProxyPortMode
        CorePids = @($Sample.CorePids)
        Listeners = @($Sample.Listeners)
        ProbeSuccess = [bool]$Sample.ProbeSuccess
        ProbeHttpCode = [string]$Sample.ProbeHttpCode
    }
    $latest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Script:LatestStatePath -Encoding UTF8
}

function Update-RuntimeState {
    param($State, $Sample)
    $sampleTime = [datetimeoffset]::Parse([string]$Sample.CheckedAt)

    if ([bool]$Sample.IsConnected) {
        $State.ConsecutiveFailures = 0
        $State.PendingFailureStart = ''

        if ($State.Status -eq 'Disconnected') {
            if ([int]$State.ConsecutiveSuccesses -eq 0) { $State.PendingRecoveryStart = $sampleTime.ToString('o') }
            $State.ConsecutiveSuccesses = [int]$State.ConsecutiveSuccesses + 1
            if ([int]$State.ConsecutiveSuccesses -ge $RecoveryThreshold) {
                $recovery = [datetimeoffset]::Parse([string]$State.PendingRecoveryStart)
                $duration = 0
                if (-not [string]::IsNullOrWhiteSpace([string]$State.DisconnectStart)) {
                    $duration = ($recovery - [datetimeoffset]::Parse([string]$State.DisconnectStart)).TotalSeconds
                }
                Write-EventRecord -EventType '恢复连接' `
                    -DisconnectStart ([datetimeoffset]::Parse([string]$State.DisconnectStart).ToString('yyyy-MM-dd HH:mm:ss')) `
                    -RecoveryTime $recovery.ToString('yyyy-MM-dd HH:mm:ss') -DurationSeconds $duration -Sample $Sample
                Write-MonitorLog -Level 'RECOVERED' -Message "龙猫云已恢复连接，断连持续 $([math]::Round($duration, 1)) 秒。"
                $State.Status = 'Connected'
                $State.DisconnectStart = ''
                $State.PendingRecoveryStart = ''
                $State.ConsecutiveSuccesses = 0
            }
        }
        else {
            if ($State.Status -eq 'Unknown') {
                Write-MonitorLog -Level 'INFO' -Message "首次确认龙猫云连接正常，端口 $($Sample.ProxyPort)。"
            }
            $State.Status = 'Connected'
            $State.PendingRecoveryStart = ''
            $State.ConsecutiveSuccesses = 0
        }
        return
    }

    $State.ConsecutiveSuccesses = 0
    $State.PendingRecoveryStart = ''
    if ($State.Status -eq 'Disconnected') { return }

    if ([int]$State.ConsecutiveFailures -eq 0) { $State.PendingFailureStart = $sampleTime.ToString('o') }
    $State.ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
    if ([int]$State.ConsecutiveFailures -ge $FailureThreshold) {
        $State.Status = 'Disconnected'
        $State.DisconnectStart = [string]$State.PendingFailureStart
        Write-EventRecord -EventType '断连开始' `
            -DisconnectStart ([datetimeoffset]::Parse([string]$State.DisconnectStart).ToString('yyyy-MM-dd HH:mm:ss')) `
            -RecoveryTime '' -DurationSeconds -1 -Sample $Sample
        Write-MonitorLog -Level 'DISCONNECTED' -Message "龙猫云断连，起始时间 $([datetimeoffset]::Parse([string]$State.DisconnectStart).ToString('yyyy-MM-dd HH:mm:ss'))；$($Sample.Reason)。"
    }
}

function Invoke-SelfTest {
    $clashListener = [pscustomobject]@{ Address = '127.0.0.1'; Port = 7890; Pid = 100; Process = 'verge-mihomo' }
    $dragonListener = [pscustomobject]@{ Address = '127.0.0.1'; Port = 7890; Pid = 200; Process = 'lmclientCore' }

    $noCore = Get-ConnectionAssessment -CoreRunning $false -Listeners @() -ProbeSuccess $false -ProbeDetail '' -Port 7890
    if ($noCore.IsConnected -or $noCore.Reason -notmatch '核心') { throw '未运行核心场景判断失败。' }

    $occupied = Get-ConnectionAssessment -CoreRunning $true -Listeners @($clashListener) -ProbeSuccess $false -ProbeDetail '' -Port 7890
    if ($occupied.IsConnected -or $occupied.Reason -notmatch 'verge-mihomo') { throw '其他客户端占用端口场景判断失败。' }

    $healthy = Get-ConnectionAssessment -CoreRunning $true -Listeners @($dragonListener) -ProbeSuccess $true -ProbeDetail '代理联网正常' -Port 7890
    if (-not $healthy.IsConnected) { throw '龙猫云正常连接场景判断失败。' }

    $dragonListener7892 = [pscustomobject]@{ Address = '127.0.0.1'; Port = 7892; Pid = 201; Process = 'lmclientCore' }
    $autoPort = Select-LongmaoProxyPort -Listeners @($clashListener, $dragonListener7892) -SystemProxyPort 7892 -PreviousPort 7890
    if ($autoPort -ne 7892) { throw '龙猫云端口自动识别没有选择系统代理当前使用的 7892。' }
    $fallbackPort = Select-LongmaoProxyPort -Listeners @($clashListener, $dragonListener7892) -SystemProxyPort 7890 -PreviousPort 0
    if ($fallbackPort -ne 7892) { throw '7890 被其他客户端占用时，端口自动识别没有回退到龙猫云的 7892。' }

    $probeFailed = Get-ConnectionAssessment -CoreRunning $true -Listeners @($dragonListener) -ProbeSuccess $false -ProbeDetail '代理联网失败' -Port 7890
    if ($probeFailed.IsConnected -or $probeFailed.Reason -notmatch '联网失败') { throw '代理不可达场景判断失败。' }

    $testDirectory = Join-Path ([IO.Path]::GetTempPath()) "network-rescue-longmao-retention-$PID"
    try {
        New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
        $rotationFile = Join-Path $testDirectory 'rotation.log'
        [IO.File]::WriteAllBytes($rotationFile, (New-Object byte[] 96))
        Invoke-FileRotation -Path $rotationFile -MaxBytes 100 -ArchiveCount 3 -IncomingBytes 10
        if (-not (Test-Path -LiteralPath "$rotationFile.1") -or (Test-Path -LiteralPath $rotationFile)) { throw '龙猫云日志轮转测试失败。' }

        $historyFile = Join-Path $testDirectory 'history.csv'
        @(
            [pscustomobject]@{ '记录时间'=(Get-Date).AddDays(-200).ToString('yyyy-MM-dd HH:mm:ss'); '事件类型'='旧记录' },
            [pscustomobject]@{ '记录时间'=(Get-Date).AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss'); '事件类型'='新记录 1' },
            [pscustomobject]@{ '记录时间'=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); '事件类型'='新记录 2' }
        ) | Export-Csv -LiteralPath $historyFile -NoTypeInformation -Encoding UTF8
        if (-not (Limit-EventHistory -Path $historyFile -RetentionDays 180 -MaxRecords 1)) { throw '龙猫云断连记录保留策略执行失败。' }
        $historyRows = @(Import-Csv -LiteralPath $historyFile -Encoding UTF8)
        if ($historyRows.Count -ne 1 -or [string]$historyRows[0].'事件类型' -ne '新记录 2') { throw '龙猫云断连记录保留边界错误。' }
    }
    finally { Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host '自检通过：核心状态、7890/7892 自动识别、端口归属、代理联网、冲突判断和记录保留限制正常。' -ForegroundColor Green
}

Initialize-DataDirectory

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($Stop) {
    Set-Content -LiteralPath $Script:StopFlagPath -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Host "已请求停止龙猫云断连监控：$Script:StopFlagPath"
    exit 0
}

if ($OpenLog) {
    Start-Process explorer.exe -ArgumentList "`"$DataDirectory`""
    exit 0
}

if ($Once) {
    Get-LiveSample | ConvertTo-Json -Depth 8
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'KerryNetworkRescueLongmaoConnectionMonitor', [ref]$createdNew)
if (-not $createdNew) {
    if ($Console) { Write-Host '龙猫云断连监控已在运行。' }
    $mutex.Dispose()
    exit 0
}

try {
    if (Test-Path -LiteralPath $Script:StopFlagPath) { Remove-Item -LiteralPath $Script:StopFlagPath -Force }
    $state = Get-RuntimeState
    $portDescription = if ($ProxyPort -eq 0) { '自动识别（优先跟随当前系统代理，候选 7890/7892）' } else { [string]$ProxyPort }
    Write-MonitorLog -Level 'INFO' -Message "龙猫云断连监控 v$Script:Version 已启动；端口=$portDescription，间隔=$IntervalSeconds 秒，断连确认=$FailureThreshold 次，恢复确认=$RecoveryThreshold 次。"

    while (-not (Test-Path -LiteralPath $Script:StopFlagPath)) {
        try {
            $sample = Get-LiveSample
            Update-RuntimeState -State $state -Sample $sample
            Save-LatestState -State $state -Sample $sample
            if ($Console) {
                Write-Host ("{0} 状态={1}；{2}" -f (Get-Date -Format 'HH:mm:ss'), $(if($sample.IsConnected){'正常'}else{'异常'}), $sample.Reason)
            }
        }
        catch {
            Write-MonitorLog -Level 'ERROR' -Message "本轮检测失败：$($_.Exception.Message)"
        }

        for ($i = 0; $i -lt ($IntervalSeconds * 2); $i++) {
            if (Test-Path -LiteralPath $Script:StopFlagPath) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    Write-MonitorLog -Level 'INFO' -Message '收到停止请求，龙猫云断连监控已退出。'
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
