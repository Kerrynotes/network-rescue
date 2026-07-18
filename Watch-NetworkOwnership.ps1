[CmdletBinding()]
param(
    [string]$ScannerPath = '',
    [string]$RepairPath = '',
    [string]$AdapterPath = '',
    [string]$DataDirectory = '',
    [ValidateRange(5, 3600)]
    [int]$IntervalSeconds = 15,
    [ValidateRange(1, 10)]
    [int]$ConfirmationSamples = 2,
    [ValidateRange(2, 10)]
    [int]$AutoRecoverySamples = 3,
    [ValidateRange(1, 60)]
    [int]$AutoRecoveryIntervalSeconds = 1,
    [switch]$DisableAutoRecovery,
    [switch]$Once,
    [switch]$SelfTest,
    [switch]$Console
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Version = '0.4.1-beta'
$Script:NotifyIcon = $null
$Script:StableState = $null
$Script:StableFingerprint = ''
$Script:PendingFingerprint = ''
$Script:PendingCount = 0
$Script:TestMode = $false
$Script:AutoRecoveryEnabled = -not $DisableAutoRecovery
$Script:StaleProxyServer = ''
$Script:StaleProxyCount = 0
$Script:UpstreamFailureSince = $null
$Script:UpstreamEventStarted = $false
$Script:UpstreamNotified = $false
$Script:UpstreamRecoveryCount = 0
$Script:UpstreamActionAvailable = $false
$Script:PendingSwitch = $null
$Script:PendingRepair = $null
$Script:LastReport = $null
$Script:AsyncScan = $null
$Script:AsyncDirectProbe = $null
$Script:AsyncSystemProxyRestoreProbe = $null
$Script:PendingSystemProxyRestore = $null
$Script:NextFullScanAt = Get-Date

if ([string]::IsNullOrWhiteSpace($ScannerPath)) {
    $ScannerPath = Join-Path $PSScriptRoot 'Scan-NetworkOwnership.ps1'
}
if ([string]::IsNullOrWhiteSpace($RepairPath)) {
    $RepairPath = Join-Path $PSScriptRoot 'Repair-Network.ps1'
}
if ([string]::IsNullOrWhiteSpace($AdapterPath)) {
    $AdapterPath = Join-Path $PSScriptRoot 'client_adapters.json'
}
if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
    $DataDirectory = Join-Path $PSScriptRoot 'monitor_data'
}

$Script:LogPath = Join-Path $DataDirectory 'monitor.log'
$Script:EventPath = Join-Path $DataDirectory 'monitor-events.jsonl'
$Script:LatestStatePath = Join-Path $DataDirectory 'latest-state.json'
$Script:LogMaxBytes = 2MB
$Script:EventMaxBytes = 5MB
$Script:ArchiveCount = 3
$Script:StopFlagPath = Join-Path $DataDirectory 'stop.request'
$Script:SettingsPath = Join-Path $DataDirectory 'settings.json'
$Script:HelperInstallerPath = Join-Path (Split-Path -Parent $RepairPath) 'Install-NetworkRescueHelper.ps1'
$Script:HelperClientPath = Join-Path (Split-Path -Parent $RepairPath) 'Invoke-NetworkRescueHelper.ps1'
$Script:HelperInstallResultPath = Join-Path $DataDirectory 'helper-install-result.json'
$Script:RepairResultPath = Join-Path $DataDirectory 'last-repair-result.json'
$Script:PathHealthScript = Join-Path (Split-Path -Parent $ScannerPath) 'Test-NetworkPathHealth.ps1'
$Script:LongmaoConnectionMonitorPath = Join-Path (Split-Path -Parent $ScannerPath) 'Monitor-LongmaoConnection.ps1'
$Script:LongmaoConnectionDataDirectory = Join-Path (Split-Path -Parent $ScannerPath) 'monitor_data\longmao_connection'
$Script:LongmaoConnectionStopFlagPath = Join-Path $Script:LongmaoConnectionDataDirectory 'stop.request'

if (-not (Test-Path -LiteralPath $DataDirectory)) {
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
}

function Invoke-FileRotation {
    param(
        [string]$Path,
        [long]$MaxBytes,
        [int]$ArchiveCount,
        [long]$IncomingBytes = 0
    )
    if ($MaxBytes -le 0 -or $ArchiveCount -lt 1 -or -not (Test-Path -LiteralPath $Path)) { return }
    $currentLength = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    if (($currentLength + $IncomingBytes) -le $MaxBytes) { return }

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

function Add-ContentWithRetry {
    param(
        [string]$Path,
        [string]$Value,
        [int]$Attempts = 4,
        [long]$MaxBytes = 0,
        [int]$ArchiveCount = 0
    )
    $incomingBytes = [Text.Encoding]::UTF8.GetByteCount($Value + [Environment]::NewLine)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-FileRotation -Path $Path -MaxBytes $MaxBytes -ArchiveCount $ArchiveCount -IncomingBytes $incomingBytes
            Add-Content -LiteralPath $Path -Value $Value -Encoding UTF8 -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds (40 * $attempt) }
        }
    }
    return $false
}

function Set-ContentWithRetry {
    param([string]$Path, [string]$Value, [int]$Attempts = 4)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8 -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds (40 * $attempt) }
        }
    }
    return $false
}

function Write-MonitorLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'EVENT')]
        [string]$Level,
        [string]$Message
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Script:TestMode) {
        [void](Add-ContentWithRetry -Path $Script:LogPath -Value $line -MaxBytes $Script:LogMaxBytes -ArchiveCount $Script:ArchiveCount)
    }
    if ($Console -or $Once -or $SelfTest) { Write-Host $line }
}

function Get-OwnershipReport {
    $output = & $ScannerPath -AdapterPath $AdapterPath -PassThru -NoWriteReport -Quiet
    $report = @($output | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'summary'
    }) | Select-Object -Last 1
    if ($null -eq $report) {
        throw '扫描器没有返回结构化网络接管报告。'
    }
    return $report
}

function Get-RelevantState {
    param($Report)
    $tunOwners = @($Report.owners.tun | ForEach-Object {
        '{0}|{1}|{2}' -f $_.Client, $_.InterfaceAlias, $_.NextHop
    } | Sort-Object)
    $tunOwnerIds = @($Report.owners.tun | Where-Object { $_.ClientId -ne 'unknown' } | Select-Object -ExpandProperty ClientId -Unique | Sort-Object)
    $conflicts = @($Report.conflicts | ForEach-Object {
        '{0}|{1}|{2}' -f $_.Severity, $_.Layer, $_.Summary
    } | Sort-Object)
    $coreClients = @($Report.clients | Where-Object { $_.HasCoreEvidence } | Select-Object -ExpandProperty Name | Sort-Object)
    $guardClients = @($Report.clients | Where-Object { $_.ProxyGuard -eq '已开启' } | Select-Object -ExpandProperty Name | Sort-Object)
    $systemOwner = if ($null -ne $Report.owners.systemProxy) { [string]$Report.owners.systemProxy.Client } else { '' }
    $systemOwnerId = if ($null -ne $Report.owners.systemProxy) { [string]$Report.owners.systemProxy.ClientId } else { '' }
    $systemProxyIsLocal = $null -ne $Report.systemProxy.Endpoint
    $staleSystemProxy = ([bool]$Report.systemProxy.Readable -and [bool]$Report.systemProxy.Enabled -and $systemProxyIsLocal -and [string]::IsNullOrWhiteSpace($systemOwner))
    $pathHealth = $Report.pathHealth
    $diagnosis = $Report.diagnosis
    $portOwners = @($Report.portOwners | ForEach-Object {
        [pscustomobject]@{
            clientId = [string]$_.ClientId; client = [string]$_.Client; port = [int]$_.Port
            pid = [int]$_.Pid; process = [string]$_.Process; startTimeUtc = [string]$_.StartTimeUtc
            uiRunning = if ($null -ne $_.PSObject.Properties['UiRunning']) { [bool]$_.UiRunning } else { $false }
        }
    })
    $environmentProxies = @($Report.environmentProxies | Where-Object { $_.Name -in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') } | ForEach-Object {
        [pscustomobject]@{ scope=[string]$_.Scope; name=[string]$_.Name; value=[string]$_.Value; endpoint=$(if($null -ne $_.Endpoint){[string]$_.Endpoint.Text}else{''}) }
    })

    return [pscustomobject][ordered]@{
        schemaVersion = 2
        version = $Script:Version
        observedAt = (Get-Date).ToString('o')
        effectiveOwner = [string]$Report.summary.effectiveOwner
        systemProxyEnabled = [bool]$Report.systemProxy.Enabled
        systemProxyServer = [string]$Report.systemProxy.Server
        systemProxyOwner = $systemOwner
        systemProxyOwnerId = $systemOwnerId
        systemProxyIsLocal = $systemProxyIsLocal
        staleSystemProxy = $staleSystemProxy
        tunOwners = $tunOwners
        tunOwnerIds = $tunOwnerIds
        conflictCount = @($Report.conflicts).Count
        conflicts = $conflicts
        coreClients = $coreClients
        proxyGuardClients = $guardClients
        diagnosisCode = [string]$diagnosis.code
        diagnosisTitle = [string]$diagnosis.title
        diagnosisMessage = [string]$diagnosis.message
        diagnosisAction = [string]$diagnosis.recommendedAction
        diagnosisOwnerIds = @($diagnosis.ownerIds)
        diagnosisFindings = @($diagnosis.findings | Select-Object code, severity, message, action)
        directStatus = if ($null -ne $pathHealth) { [string]$pathHealth.direct.status } else { 'NotTested' }
        directHealthy = if ($null -ne $pathHealth) { [bool]$pathHealth.direct.healthy } else { $false }
        proxyStatus = if ($null -ne $pathHealth) { [string]$pathHealth.proxy.status } else { 'NotTested' }
        proxyHealthy = if ($null -ne $pathHealth) { [bool]$pathHealth.proxy.healthy } else { $false }
        proxyFailureCandidate = if ($null -ne $pathHealth) { [bool]$pathHealth.proxyFailureCandidate } else { $false }
        dnsStatus = if ($null -ne $pathHealth) { [string]$pathHealth.dns.status } else { 'NotTested' }
        portOwners = $portOwners
        environmentProxies = $environmentProxies
        warningCount = @($Report.warnings).Count
    }
}

function Get-StateFingerprint {
    param($State)
    $ownershipDiagnosis = if ($State.diagnosisCode -in @('ProxyPathDegraded','LocalNetworkFailure')) { '' } else { [string]$State.diagnosisCode }
    $fingerprintInput = [pscustomobject][ordered]@{
        effectiveOwner = $State.effectiveOwner
        systemProxyEnabled = $State.systemProxyEnabled
        systemProxyServer = $State.systemProxyServer
        systemProxyOwner = $State.systemProxyOwner
        systemProxyOwnerId = $State.systemProxyOwnerId
        staleSystemProxy = $State.staleSystemProxy
        tunOwners = @($State.tunOwners)
        conflicts = @($State.conflicts)
        coreClients = @($State.coreClients)
        proxyGuardClients = @($State.proxyGuardClients)
        ownershipDiagnosis = $ownershipDiagnosis
        tunOwnerIds = @($State.tunOwnerIds)
        portOwners = @($State.portOwners | ForEach-Object { "$($_.clientId)|$($_.port)|$($_.pid)|$($_.startTimeUtc)" } | Sort-Object)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($fingerprintInput | ConvertTo-Json -Compress -Depth 8))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-ChangeEvent {
    param($OldState, $NewState)

    if ($OldState.systemProxyEnabled -and -not $NewState.systemProxyEnabled -and -not [string]::IsNullOrWhiteSpace([string]$OldState.systemProxyOwner)) {
        $newCoreClients = @($NewState.coreClients | Where-Object { @($OldState.coreClients) -notcontains $_ })
        $extra = if ($newCoreClients.Count -gt 0) { " 同时发现新启动的客户端核心：$($newCoreClients -join '、')。" } else { '' }
        return [pscustomobject]@{
            Type = 'SystemProxyUnexpectedlyDisabled'
            Title = 'Windows 系统代理已被关闭'
            Text = "原 Owner 为 $($OldState.systemProxyOwner)，其核心仍可能运行。$extra 普通互联网可能可用，但 ChatGPT 直连可能失败；请回主客户端手动重新连接。"
            Icon = 'Warning'
        }
    }

    $newEmergency = @($NewState.conflicts | Where-Object { $_ -match '^紧急\|' })
    $oldEmergency = @($OldState.conflicts | Where-Object { $_ -match '^紧急\|' })
    if ($newEmergency.Count -gt $oldEmergency.Count) {
        return [pscustomobject]@{
            Type = 'EmergencyConflict'
            Title = '检测到失效网络接管'
            Text = ($newEmergency[0] -split '\|', 3)[2]
            Icon = 'Error'
        }
    }
    if ($NewState.conflictCount -gt $OldState.conflictCount) {
        return [pscustomobject]@{
            Type = 'ConflictDetected'
            Title = '检测到代理客户端冲突'
            Text = "冲突从 $($OldState.conflictCount) 项增加到 $($NewState.conflictCount) 项，请查看网络 Owner。"
            Icon = 'Warning'
        }
    }
    if ($OldState.conflictCount -gt 0 -and $NewState.conflictCount -eq 0) {
        return [pscustomobject]@{
            Type = 'ConflictResolved'
            Title = '代理接管冲突已解除'
            Text = "当前有效 Owner：$($NewState.effectiveOwner)"
            Icon = 'Info'
        }
    }
    if ($OldState.effectiveOwner -ne $NewState.effectiveOwner) {
        return [pscustomobject]@{
            Type = 'OwnerChanged'
            Title = '网络 Owner 已变化'
            Text = "$($OldState.effectiveOwner) → $($NewState.effectiveOwner)"
            Icon = 'Info'
        }
    }
    if ($OldState.systemProxyEnabled -ne $NewState.systemProxyEnabled) {
        return [pscustomobject]@{
            Type = 'SystemProxyChanged'
            Title = 'Windows 系统代理已变化'
            Text = if ($NewState.systemProxyEnabled) { "已开启：$($NewState.systemProxyServer)" } else { '已关闭' }
            Icon = 'Info'
        }
    }
    return [pscustomobject]@{
        Type = 'OwnershipStateChanged'
        Title = '网络接管状态已变化'
        Text = "当前有效 Owner：$($NewState.effectiveOwner)"
        Icon = 'Info'
    }
}

function Write-StateEvent {
    param($Event, $OldState, $NewState)
    $record = [pscustomobject][ordered]@{
        timestamp = (Get-Date).ToString('o')
        eventType = $Event.Type
        title = $Event.Title
        message = $Event.Text
        oldState = $OldState
        newState = $NewState
    }
    if (-not $Script:TestMode) {
        [void](Add-ContentWithRetry -Path $Script:EventPath -Value ($record | ConvertTo-Json -Compress -Depth 10) -MaxBytes $Script:EventMaxBytes -ArchiveCount $Script:ArchiveCount)
        [void](Set-ContentWithRetry -Path $Script:LatestStatePath -Value ($NewState | ConvertTo-Json -Depth 8))
    }
    Write-MonitorLog -Level 'EVENT' -Message "$($Event.Title)：$($Event.Text)"
}

function Write-StructuredEvent {
    param([string]$Type, [string]$Title, [string]$Message, $Data = $null)
    $record = [pscustomobject][ordered]@{
        schemaVersion = 2
        timestamp = (Get-Date).ToString('o')
        eventType = $Type
        title = $Title
        message = $Message
        data = $Data
    }
    if (-not $Script:TestMode) {
        [void](Add-ContentWithRetry -Path $Script:EventPath -Value ($record | ConvertTo-Json -Compress -Depth 10) -MaxBytes $Script:EventMaxBytes -ArchiveCount $Script:ArchiveCount)
    }
    Write-MonitorLog -Level 'EVENT' -Message "$Title：$Message"
}

function Write-NewDiagnosisEvents {
    param($OldState, $NewState)
    $oldCodes = @($OldState.diagnosisFindings | Select-Object -ExpandProperty code -Unique)
    foreach ($finding in @($NewState.diagnosisFindings | Where-Object { $oldCodes -notcontains $_.code })) {
        $eventType = switch ([string]$finding.code) {
            'PortOccupiedByOtherClient' { 'PortOwnerDetected' }
            'SharedRuntimeConflict' { 'SharedRuntimeConflictDetected' }
            'ClientIpcBroken' { 'ClientIpcBrokenDetected' }
            'OrphanCore' { 'PortOwnerDetected' }
            'TunResidual' { 'TunConflictDetected' }
            'TunConflictDetected' { 'TunConflictDetected' }
            'ApplicationPathSplit' { 'ApplicationPathSplitDetected' }
            default { '' }
        }
        if ($eventType) {
            Write-StructuredEvent -Type $eventType -Title ([string]$finding.code) -Message ([string]$finding.message) -Data $finding
        }
    }
}

function Show-MonitorNotification {
    param($Event)
    if ($null -eq $Script:NotifyIcon) { return }
    $Script:NotifyIcon.BalloonTipTitle = [string]$Event.Title
    $Script:NotifyIcon.BalloonTipText = [string]$Event.Text
    $Script:NotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$($Event.Icon)
    $Script:NotifyIcon.ShowBalloonTip(6000)
}

function Invoke-TrayActionSafely {
    param([string]$ActionName, [scriptblock]$Action)
    try {
        & $Action
    }
    catch {
        $detail = $_.Exception.Message
        Write-MonitorLog -Level 'ERROR' -Message "$ActionName 失败：$detail"
        if ($Script:TestMode) { return }
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "操作没有完成，但后台监控会继续运行。`r`n`r`n原因：$detail`r`n`r`n请稍后重试；如果持续出现，请打开诊断报告与运行记录。",
                '断网急救',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        catch {}
    }
}

function Set-TrayAppearance {
    param($State)
    if ($null -eq $Script:NotifyIcon) { return }
    $status = if ($Script:UpstreamNotified) {
        '代理线路持续异常'
    }
    elseif ($null -ne $Script:UpstreamFailureSince -and ((Get-Date) - $Script:UpstreamFailureSince).TotalSeconds -ge 30) {
        '代理线路暂时异常'
    }
    elseif ($State.conflictCount -gt 0) { "冲突 $($State.conflictCount) 项" } else { [string]$State.effectiveOwner }
    $text = "断网急救：$status"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $Script:NotifyIcon.Text = $text
}

function Reset-UpstreamHealthState {
    $Script:UpstreamFailureSince = $null
    $Script:UpstreamEventStarted = $false
    $Script:UpstreamNotified = $false
    $Script:UpstreamRecoveryCount = 0
    $Script:UpstreamActionAvailable = $false
}

function Update-UpstreamHealth {
    param($State)
    if ($State.proxyFailureCandidate) {
        $Script:UpstreamRecoveryCount = 0
        if ($null -eq $Script:UpstreamFailureSince) {
            $Script:UpstreamFailureSince = Get-Date
            Write-MonitorLog -Level 'WARN' -Message '多个代理探测目标失败，开始观察；30 秒内不弹窗，避免短时抖动打扰。'
        }
        $elapsedSeconds = [int]((Get-Date) - $Script:UpstreamFailureSince).TotalSeconds
        if ($elapsedSeconds -ge 60 -and -not $Script:UpstreamEventStarted) {
            $Script:UpstreamEventStarted = $true
            Write-StructuredEvent -Type 'UpstreamOutageStarted' -Title '代理线路故障已确认' `
                -Message '本地端口和普通网络正常，但多个代理联网目标持续失败；不会自动关闭代理。' `
                -Data ([pscustomobject]@{ owner=$State.effectiveOwner; endpoint=$State.systemProxyServer; elapsedSeconds=$elapsedSeconds })
        }
        if ($elapsedSeconds -ge 180 -and -not $Script:UpstreamNotified) {
            $Script:UpstreamNotified = $true
            $Script:UpstreamActionAvailable = $true
            Show-MonitorNotification -Event ([pscustomobject]@{
                Title='代理线路持续异常'
                Text='本地代理仍在运行，但线路已连续失败约 3 分钟。请更新节点；点击此通知可选择恢复普通网络。'
                Icon='Warning'
            })
        }
        Set-TrayAppearance -State $State
        return
    }

    if ($null -eq $Script:UpstreamFailureSince) { return }
    if ($State.proxyHealthy) {
        $Script:UpstreamRecoveryCount++
        if ($Script:UpstreamRecoveryCount -lt 2) { return }
        $duration = [math]::Round(((Get-Date) - $Script:UpstreamFailureSince).TotalSeconds, 1)
        if ($Script:UpstreamEventStarted) {
            Write-StructuredEvent -Type 'UpstreamOutageRecovered' -Title '代理线路已恢复' `
                -Message "代理联网连续两次恢复，故障持续约 $duration 秒。" `
                -Data ([pscustomobject]@{ owner=$State.effectiveOwner; endpoint=$State.systemProxyServer; durationSeconds=$duration })
        }
        $wasNotified = $Script:UpstreamNotified
        Reset-UpstreamHealthState
        if ($wasNotified) { Show-MonitorNotification -Event ([pscustomobject]@{ Title='代理线路已恢复'; Text="代理联网已恢复，之前的故障持续约 $duration 秒。"; Icon='Info' }) }
        Set-TrayAppearance -State $State
    }
}

function Accept-InitialState {
    param($State, [string]$Fingerprint)
    $Script:StableState = $State
    $Script:StableFingerprint = $Fingerprint
    $Script:PendingFingerprint = ''
    $Script:PendingCount = 0
    if (-not $Script:TestMode) { [void](Set-ContentWithRetry -Path $Script:LatestStatePath -Value ($State | ConvertTo-Json -Depth 8)) }
    Write-MonitorLog -Level 'INFO' -Message "初始状态：Owner=$($State.effectiveOwner)，冲突=$($State.conflictCount) 项。"
    Write-NewDiagnosisEvents -OldState ([pscustomobject]@{ diagnosisFindings=@() }) -NewState $State
    Set-TrayAppearance -State $State
}

function Submit-MonitorSample {
    param($State)
    $fingerprint = Get-StateFingerprint -State $State

    if ($null -eq $Script:StableState) {
        Accept-InitialState -State $State -Fingerprint $fingerprint
        return $false
    }
    if ($fingerprint -eq $Script:StableFingerprint) {
        $Script:PendingFingerprint = ''
        $Script:PendingCount = 0
        $Script:StableState = $State
        if (-not $Script:TestMode) { [void](Set-ContentWithRetry -Path $Script:LatestStatePath -Value ($State | ConvertTo-Json -Depth 10)) }
        Set-TrayAppearance -State $State
        return $false
    }
    if ($fingerprint -eq $Script:PendingFingerprint) {
        $Script:PendingCount++
    }
    else {
        $Script:PendingFingerprint = $fingerprint
        $Script:PendingCount = 1
    }
    Write-MonitorLog -Level 'INFO' -Message "发现候选变化，确认进度 $($Script:PendingCount)/$ConfirmationSamples。"
    if ($Script:PendingCount -lt $ConfirmationSamples) { return $false }

    $oldState = $Script:StableState
    $event = Get-ChangeEvent -OldState $oldState -NewState $State
    $autoRestoreCandidate = Get-SystemProxyAutoRestoreCandidate -OldState $oldState -NewState $State
    $Script:StableState = $State
    $Script:StableFingerprint = $fingerprint
    $Script:PendingFingerprint = ''
    $Script:PendingCount = 0
    Write-StateEvent -Event $event -OldState $oldState -NewState $State
    Write-NewDiagnosisEvents -OldState $oldState -NewState $State
    Set-TrayAppearance -State $State
    Show-MonitorNotification -Event $event
    if ($null -ne $autoRestoreCandidate) {
        $Script:PendingSystemProxyRestore = $autoRestoreCandidate
        [void](Start-AsyncSystemProxyRestoreTest -Candidate $autoRestoreCandidate)
    }
    return $true
}

function Start-AsyncDirectInternetTest {
    param([string]$ProxyServer)
    if ($null -ne $Script:AsyncDirectProbe) { return $false }

    $escapedPath = $Script:PathHealthScript.Replace("'", "''")
    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$output = & '$escapedPath' -SkipProxy -TimeoutSeconds 6 -PassThru
`$health = @(`$output | Where-Object { `$null -ne `$_ -and `$_.PSObject.Properties.Name -contains 'schemaVersion' }) | Select-Object -Last 1
if (`$null -eq `$health) { throw '普通网络探测没有返回结构化结果。' }
[pscustomobject]@{
    ProbeKind = 'DirectInternet'
    Healthy = [bool]`$health.direct.healthy
    Status = [string]`$health.direct.status
}
"@
    $powerShell = [PowerShell]::Create()
    [void]$powerShell.AddScript($scriptText)
    $async = $powerShell.BeginInvoke()
    $Script:AsyncDirectProbe = [pscustomobject]@{
        PowerShell = $powerShell
        Async = $async
        ProxyServer = $ProxyServer
        StartedAt = Get-Date
    }
    Write-MonitorLog -Level 'INFO' -Message "普通网络确认已转入后台，不阻塞托盘菜单：$ProxyServer。"
    return $true
}

function Complete-AsyncDirectInternetTest {
    if ($null -eq $Script:AsyncDirectProbe -or -not $Script:AsyncDirectProbe.Async.IsCompleted) { return $null }
    $probe = $Script:AsyncDirectProbe
    $Script:AsyncDirectProbe = $null
    try {
        $output = $probe.PowerShell.EndInvoke($probe.Async)
        if ($probe.PowerShell.HadErrors) {
            $errors = @($probe.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '；'
            throw "后台普通网络探测失败：$errors"
        }
        $result = @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ProbeKind' }) | Select-Object -Last 1
        if ($null -eq $result) { throw '后台普通网络探测没有返回结果。' }
        return [pscustomobject]@{
            ProxyServer = [string]$probe.ProxyServer
            Healthy = [bool]$result.Healthy
            Status = [string]$result.Status
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            ProxyServer = [string]$probe.ProxyServer
            Healthy = $false
            Status = 'Failed'
            Error = $_.Exception.Message
        }
    }
    finally { $probe.PowerShell.Dispose() }
}

function Get-LocalProxyPortFromServer {
    param([string]$Server)
    if ([string]::IsNullOrWhiteSpace($Server)) { return 0 }
    $match = [regex]::Match($Server, '(?i)(?:https?=|socks=)?(?:https?://|socks5?://)?(?:127\.0\.0\.1|localhost|\[::1\]|::1)\s*:\s*(?<port>\d{1,5})')
    if (-not $match.Success) { return 0 }
    $port = [int]$match.Groups['port'].Value
    if ($port -lt 1 -or $port -gt 65535) { return 0 }
    return $port
}

function Get-SystemProxyAutoRestoreCandidate {
    param($OldState, $NewState)

    if (-not $Script:AutoRecoveryEnabled -or $null -eq $OldState -or $null -eq $NewState) { return $null }
    if (-not [bool]$OldState.systemProxyEnabled -or [bool]$NewState.systemProxyEnabled) { return $null }
    if (-not [bool]$OldState.systemProxyIsLocal -or [string]::IsNullOrWhiteSpace([string]$OldState.systemProxyOwnerId)) { return $null }
    if (-not [bool]$OldState.proxyHealthy) { return $null }
    if ([string]$OldState.systemProxyServer -ne [string]$NewState.systemProxyServer) { return $null }
    if (@($OldState.tunOwnerIds).Count -gt 0 -or @($NewState.tunOwnerIds).Count -gt 0) { return $null }
    if (@($NewState.proxyGuardClients).Count -gt 0) { return $null }
    if (@($NewState.coreClients) -notcontains [string]$OldState.systemProxyOwner) { return $null }

    $disappearedClients = @($OldState.coreClients | Where-Object {
        $_ -ne [string]$OldState.systemProxyOwner -and @($NewState.coreClients) -notcontains $_
    })
    if ($disappearedClients.Count -eq 0) { return $null }

    $port = Get-LocalProxyPortFromServer -Server ([string]$OldState.systemProxyServer)
    if ($port -eq 0) { return $null }
    $portOwner = @($NewState.portOwners | Where-Object {
        $_.clientId -eq [string]$OldState.systemProxyOwnerId -and [int]$_.port -eq $port
    }) | Select-Object -First 1
    if ($null -eq $portOwner) { return $null }

    return [pscustomobject]@{
        Endpoint = [string]$OldState.systemProxyServer
        Port = $port
        OwnerId = [string]$OldState.systemProxyOwnerId
        Owner = [string]$OldState.systemProxyOwner
        ExpectedPid = [int]$portOwner.pid
        ExpectedProcess = [string]$portOwner.process
        DisappearedClients = $disappearedClients
        DetectedAt = Get-Date
    }
}

function Start-AsyncSystemProxyRestoreTest {
    param($Candidate)
    if ($null -eq $Candidate -or $null -ne $Script:AsyncSystemProxyRestoreProbe) { return $false }

    $escapedPath = $Script:PathHealthScript.Replace("'", "''")
    $escapedEndpoint = ([string]$Candidate.Endpoint).Replace("'", "''")
    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$output = & '$escapedPath' -ProxyEndpoint '$escapedEndpoint' -SkipDirect -TimeoutSeconds 6 -PassThru
`$health = @(`$output | Where-Object { `$null -ne `$_ -and `$_.PSObject.Properties.Name -contains 'schemaVersion' }) | Select-Object -Last 1
if (`$null -eq `$health) { throw '代理联网复核没有返回结构化结果。' }
[pscustomobject]@{
    ProbeKind = 'SystemProxyRestore'
    Healthy = [bool]`$health.proxy.healthy
    Status = [string]`$health.proxy.status
    Pid = [int]`$health.proxy.pid
    Process = [string]`$health.proxy.process
}
"@
    $powerShell = [PowerShell]::Create()
    [void]$powerShell.AddScript($scriptText)
    $async = $powerShell.BeginInvoke()
    $Script:AsyncSystemProxyRestoreProbe = [pscustomobject]@{
        PowerShell = $powerShell
        Async = $async
        Candidate = $Candidate
        StartedAt = Get-Date
    }
    Write-MonitorLog -Level 'INFO' -Message "检测到 $($Candidate.DisappearedClients -join '、') 退出时关闭了 $($Candidate.Owner) 的系统代理；已转入后台复核 $($Candidate.Endpoint)。"
    return $true
}

function Complete-AsyncSystemProxyRestoreTest {
    if ($null -eq $Script:AsyncSystemProxyRestoreProbe -or -not $Script:AsyncSystemProxyRestoreProbe.Async.IsCompleted) { return $null }
    $probe = $Script:AsyncSystemProxyRestoreProbe
    $Script:AsyncSystemProxyRestoreProbe = $null
    try {
        $output = $probe.PowerShell.EndInvoke($probe.Async)
        if ($probe.PowerShell.HadErrors) {
            $errors = @($probe.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '；'
            throw "后台代理联网复核失败：$errors"
        }
        $result = @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'ProbeKind' }) | Select-Object -Last 1
        if ($null -eq $result) { throw '后台代理联网复核没有返回结果。' }
        return [pscustomobject]@{
            Candidate = $probe.Candidate
            Healthy = [bool]$result.Healthy
            Status = [string]$result.Status
            Pid = [int]$result.Pid
            Process = [string]$result.Process
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Candidate = $probe.Candidate
            Healthy = $false
            Status = 'Failed'
            Pid = 0
            Process = ''
            Error = $_.Exception.Message
        }
    }
    finally { $probe.PowerShell.Dispose() }
}

function Enable-ExpectedSystemProxy {
    param($Candidate, $ProbeResult)
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    $enabledProperty = $item.PSObject.Properties['ProxyEnable']
    $serverProperty = $item.PSObject.Properties['ProxyServer']
    $enabled = if ($null -ne $enabledProperty) { [int]$enabledProperty.Value } else { 0 }
    $server = if ($null -ne $serverProperty) { [string]$serverProperty.Value } else { '' }
    if ($enabled -ne 0 -or $server -ne [string]$Candidate.Endpoint) {
        Write-MonitorLog -Level 'INFO' -Message '代理联网复核完成前 Windows 代理状态已经变化，本次不自动重开。'
        return $false
    }
    if ([int]$ProbeResult.Pid -ne [int]$Candidate.ExpectedPid -or [string]$ProbeResult.Process -ne [string]$Candidate.ExpectedProcess) {
        Write-MonitorLog -Level 'WARN' -Message "端口 $($Candidate.Port) 的监听者已变化，本次不自动重开系统代理。"
        return $false
    }

    Set-ItemProperty -LiteralPath $path -Name ProxyEnable -Type DWord -Value 1 -ErrorAction Stop
    Initialize-WinInetApi
    [NetworkRescueMonitor.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [NetworkRescueMonitor.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    $verified = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if ([int]$verified.ProxyEnable -ne 1 -or [string]$verified.ProxyServer -ne [string]$Candidate.Endpoint) { throw '自动重开系统代理后复核失败。' }
    Write-MonitorLog -Level 'EVENT' -Message "自动急救已恢复 $($Candidate.Owner) 的 Windows 系统代理：$($Candidate.Endpoint)。"
    return $true
}

function Complete-PendingSystemProxyRestore {
    $result = Complete-AsyncSystemProxyRestoreTest
    if ($null -eq $result) { return $false }
    $candidate = $result.Candidate
    $Script:PendingSystemProxyRestore = $null

    if (-not $Script:AutoRecoveryEnabled -or $null -eq $Script:StableState -or [bool]$Script:StableState.systemProxyEnabled -or @($Script:StableState.tunOwnerIds).Count -gt 0) {
        Write-MonitorLog -Level 'INFO' -Message '代理联网复核完成前接管状态已经变化，本次不自动重开系统代理。'
        return $false
    }
    if (-not $result.Healthy) {
        $detail = if ([string]::IsNullOrWhiteSpace([string]$result.Error)) { [string]$result.Status } else { [string]$result.Error }
        Write-MonitorLog -Level 'WARN' -Message "保留的代理核心未通过联网复核，本次不自动重开系统代理：$detail"
        return $false
    }

    $restored = Enable-ExpectedSystemProxy -Candidate $candidate -ProbeResult $result
    if ($restored) {
        Write-StructuredEvent -Type 'SystemProxyAutoRestored' -Title 'Windows 系统代理已自动恢复' `
            -Message "$($candidate.DisappearedClients -join '、') 退出时关闭了系统代理；已确认 $($candidate.Owner) 的原端口和代理联网正常，并恢复 $($candidate.Endpoint)。" `
            -Data ([pscustomobject]@{ endpoint=$candidate.Endpoint; ownerId=$candidate.OwnerId; owner=$candidate.Owner; pid=$candidate.ExpectedPid; disappearedClients=@($candidate.DisappearedClients) })
        Show-MonitorNotification -Event ([pscustomobject]@{ Title='代理上网已自动恢复'; Text="已重新启用 $($candidate.Owner) 的 Windows 系统代理。"; Icon='Info' })
        $Script:NextFullScanAt = Get-Date
    }
    return $restored
}

function Initialize-WinInetApi {
    if ('NetworkRescueMonitor.WinInet' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NetworkRescueMonitor {
    public static class WinInet {
        [DllImport("wininet.dll", SetLastError = true)]
        public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
    }
}
'@
}

function Disable-StaleSystemProxy {
    param([string]$ExpectedServer)
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    $enabledProperty = $item.PSObject.Properties['ProxyEnable']
    $serverProperty = $item.PSObject.Properties['ProxyServer']
    $enabled = if ($null -ne $enabledProperty) { [int]$enabledProperty.Value } else { 0 }
    $server = if ($null -ne $serverProperty) { [string]$serverProperty.Value } else { '' }
    if ($enabled -ne 1 -or $server -ne $ExpectedServer) {
        Write-MonitorLog -Level 'INFO' -Message '自动急救执行前状态已经变化，本次不修改系统代理。'
        return $false
    }

    Set-ItemProperty -LiteralPath $path -Name ProxyEnable -Type DWord -Value 0 -ErrorAction Stop
    Initialize-WinInetApi
    [NetworkRescueMonitor.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [NetworkRescueMonitor.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    $verified = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if ([int]$verified.ProxyEnable -ne 0) { throw '自动关闭系统代理后复核失败。' }
    Write-MonitorLog -Level 'EVENT' -Message "自动急救已关闭失效系统代理：$ExpectedServer；普通网络直连探针正常。"
    return $true
}

function Submit-AutoRecoverySample {
    param($State)

    if (-not $Script:AutoRecoveryEnabled -or -not $State.staleSystemProxy) {
        $Script:StaleProxyServer = ''
        $Script:StaleProxyCount = 0
        return $false
    }
    if (@($State.proxyGuardClients).Count -gt 0) {
        if ($Script:StaleProxyCount -eq 0) {
            Write-MonitorLog -Level 'WARN' -Message "检测到失效系统代理，但客户端代理守护已开启：$($State.proxyGuardClients -join '、')；为避免争抢，本次不自动修改。"
        }
        $Script:StaleProxyServer = $State.systemProxyServer
        $Script:StaleProxyCount = 1
        return $false
    }
    if ($Script:StaleProxyServer -eq $State.systemProxyServer -and
        $Script:StaleProxyCount -ge $AutoRecoverySamples -and
        $null -ne $Script:AsyncDirectProbe) {
        return $false
    }
    if ($Script:StaleProxyServer -eq $State.systemProxyServer) {
        $Script:StaleProxyCount++
    }
    else {
        $Script:StaleProxyServer = $State.systemProxyServer
        $Script:StaleProxyCount = 1
    }
    Write-MonitorLog -Level 'WARN' -Message "失效系统代理确认进度 $($Script:StaleProxyCount)/$AutoRecoverySamples：$($State.systemProxyServer)。"
    if ($Script:StaleProxyCount -lt $AutoRecoverySamples -or $Script:TestMode) { return $false }
    [void](Start-AsyncDirectInternetTest -ProxyServer $State.systemProxyServer)
    return $false
}

function Complete-PendingAutoRecovery {
    $result = Complete-AsyncDirectInternetTest
    if ($null -eq $result) { return $false }

    $current = Get-LightweightStaleProxyState
    $guardClients = if ($null -ne $Script:StableState) { @($Script:StableState.proxyGuardClients) } else { @() }
    if (-not $Script:AutoRecoveryEnabled -or -not $current.Stale -or $current.Server -ne $result.ProxyServer) {
        Write-MonitorLog -Level 'INFO' -Message '后台普通网络探测完成前代理状态已经变化，本次不修改系统代理。'
        $Script:StaleProxyServer = ''
        $Script:StaleProxyCount = 0
        return $false
    }
    if ($guardClients.Count -gt 0) {
        Write-MonitorLog -Level 'WARN' -Message "后台探测完成，但检测到代理守护已开启：$($guardClients -join '、')；本次不自动修改。"
        $Script:StaleProxyCount = 1
        return $false
    }
    if (-not $result.Healthy) {
        $detail = if ([string]::IsNullOrWhiteSpace($result.Error)) { $result.Status } else { $result.Error }
        Write-MonitorLog -Level 'WARN' -Message "普通网络直连探针失败，不把故障单独归因于系统代理，本次不自动修复：$detail"
        $Script:StaleProxyCount = 0
        return $false
    }

    $recovered = Disable-StaleSystemProxy -ExpectedServer $result.ProxyServer
    $Script:StaleProxyServer = ''
    $Script:StaleProxyCount = 0
    if ($recovered) {
        Write-StructuredEvent -Type 'StaleProxyDisabled' -Title '失效系统代理已自动关闭' `
            -Message "已关闭无人监听的系统代理 $($result.ProxyServer)，没有结束客户端或修改 TUN、DNS和环境变量。" `
            -Data ([pscustomobject]@{ endpoint=$result.ProxyServer; samples=$AutoRecoverySamples })
        $event = [pscustomobject]@{ Title = '普通网络已自动恢复'; Text = '已关闭无人监听的失效 Windows 系统代理；请回原客户端手动重新连接。'; Icon = 'Info' }
        Show-MonitorNotification -Event $event
    }
    return $recovered
}

function Get-LightweightStaleProxyState {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $enabledProperty = $item.PSObject.Properties['ProxyEnable']
        $serverProperty = $item.PSObject.Properties['ProxyServer']
        $enabled = ($null -ne $enabledProperty -and [int]$enabledProperty.Value -eq 1)
        $server = if ($null -ne $serverProperty) { [string]$serverProperty.Value } else { '' }
        if (-not $enabled -or [string]::IsNullOrWhiteSpace($server)) {
            return [pscustomobject]@{ Enabled = $enabled; Server = $server; IsLocal = $false; HasListener = $false; Stale = $false }
        }

        $match = [regex]::Match($server, '(?i)(?:https?=)?(?:https?://)?(127\.0\.0\.1|localhost|\[?::1\]?):([0-9]{1,5})')
        if (-not $match.Success) {
            return [pscustomobject]@{ Enabled = $true; Server = $server; IsLocal = $false; HasListener = $false; Stale = $false }
        }
        $port = [int]$match.Groups[2].Value
        if ($port -lt 1 -or $port -gt 65535) {
            return [pscustomobject]@{ Enabled = $true; Server = $server; IsLocal = $false; HasListener = $false; Stale = $false }
        }
        # 原 CIM 端口查询实测单次可阻塞 UI 0.5～1.4 秒；这里改用本机 IP Helper 快照。
        $listener = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
            Where-Object { $_.Port -eq $port }).Count -gt 0
        return [pscustomobject]@{ Enabled = $true; Server = $server; IsLocal = $true; HasListener = $listener; Stale = -not $listener }
    }
    catch {
        Write-MonitorLog -Level 'ERROR' -Message "轻量急救检查失败：$($_.Exception.Message)"
        return [pscustomobject]@{ Enabled = $false; Server = ''; IsLocal = $false; HasListener = $false; Stale = $false }
    }
}

function Invoke-LightweightAutoRecoveryCheck {
    $proxy = Get-LightweightStaleProxyState
    $guardClients = if ($null -ne $Script:StableState) { @($Script:StableState.proxyGuardClients) } else { @() }
    $state = [pscustomobject]@{
        staleSystemProxy = [bool]$proxy.Stale
        systemProxyServer = [string]$proxy.Server
        proxyGuardClients = $guardClients
    }
    return (Submit-AutoRecoverySample -State $state)
}

function Invoke-MonitorScan {
    $report = Get-OwnershipReport
    return (Submit-OwnershipReport -Report $report)
}

function Submit-OwnershipReport {
    param($Report)
    $report = $Report
    $Script:LastReport = $report
    $state = Get-RelevantState -Report $report
    Submit-MonitorSample -State $state | Out-Null
    Update-UpstreamHealth -State $state
    Update-PendingRepairAndSwitch -Report $report -State $state
    return [pscustomobject]@{ Report = $report; State = $state }
}

function Start-AsyncMonitorScan {
    if ($null -ne $Script:AsyncScan) { return }
    $escapedScanner = $ScannerPath.Replace("'", "''")
    $escapedAdapter = $AdapterPath.Replace("'", "''")
    $scriptText = "& '$escapedScanner' -AdapterPath '$escapedAdapter' -PassThru -NoWriteReport -Quiet"
    $powerShell = [PowerShell]::Create()
    [void]$powerShell.AddScript($scriptText)
    $async = $powerShell.BeginInvoke()
    $Script:AsyncScan = [pscustomobject]@{ PowerShell=$powerShell; Async=$async; StartedAt=Get-Date }
}

function Complete-AsyncMonitorScan {
    if ($null -eq $Script:AsyncScan -or -not $Script:AsyncScan.Async.IsCompleted) { return $false }
    $scan = $Script:AsyncScan
    $Script:AsyncScan = $null
    try {
        $output = $scan.PowerShell.EndInvoke($scan.Async)
        if ($scan.PowerShell.HadErrors) {
            $errors = @($scan.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '；'
            throw "异步扫描失败：$errors"
        }
        $report = @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'summary' }) | Select-Object -Last 1
        if ($null -eq $report) { throw '异步扫描没有返回结构化报告。' }
        [void](Submit-OwnershipReport -Report $report)
        return $true
    }
    finally { $scan.PowerShell.Dispose() }
}

function Test-HelperAvailableFromTray {
    if (-not (Test-Path -LiteralPath $Script:HelperClientPath)) { return $false }
    try {
        $result = & $Script:HelperClientPath -Mode Ping -TimeoutMilliseconds 1500 -PassThru
        return ($null -ne $result -and [bool]$result.success)
    }
    catch { return $false }
}

function Get-HelperInstallFailureMessage {
    param($Result, [int]$ExitCode)

    if ($null -ne $Result -and $Result.PSObject.Properties.Name -contains 'message' -and -not [string]::IsNullOrWhiteSpace([string]$Result.message)) {
        $stage = if ($Result.PSObject.Properties.Name -contains 'stage' -and -not [string]::IsNullOrWhiteSpace([string]$Result.stage)) { [string]$Result.stage } else { '安装 Helper' }
        return "$stage：$([string]$Result.message)"
    }
    if ($ExitCode -eq 1223) {
        return 'Windows 管理员授权窗口被取消或关闭。'
    }
    $service = Get-Service -Name 'KerryNetworkRescueHelper' -ErrorAction SilentlyContinue
    $partialDirectory = Join-Path $env:ProgramFiles 'KerryNetworkRescueHelper'
    if ($null -eq $service -and (Test-Path -LiteralPath $partialDirectory)) {
        return '检测到 Helper 文件残留，但 Windows 服务没有创建成功。通常是 UAC 未确认或安装被中断。'
    }
    if ($null -ne $service) {
        return "Windows 服务状态为 $($service.Status)，但通信验证失败。"
    }
    return "安装进程退出码为 $ExitCode，且没有返回详细结果。"
}

function Get-PrivilegeStrategy {
    if (Test-HelperAvailableFromTray) { return 'Helper' }
    $result = [System.Windows.Forms.MessageBox]::Show(
        "这个操作需要停止受保护的核心、服务或 TUN。`r`n`r`n选择【是】：安装 Helper，只在本次安装时确认一次 UAC；以后仍会在断网急救里确认操作，但不再弹 UAC。`r`n`r`n选择【否】：不安装 Helper，仅本次请求 UAC。`r`n`r`n选择【取消】：不执行。",
        '需要管理员权限',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) { return 'Cancel' }
    if ($result -eq [System.Windows.Forms.DialogResult]::No) { return 'ElevateOnce' }
    if (-not (Test-Path -LiteralPath $Script:HelperInstallerPath)) {
        [System.Windows.Forms.MessageBox]::Show('未找到 Helper 安装组件，本次操作已取消。', '断网急救', 'OK', 'Error') | Out-Null
        return 'Cancel'
    }
    try {
        Remove-Item -LiteralPath $Script:HelperInstallResultPath -Force -ErrorAction SilentlyContinue
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Script:HelperInstallerPath`" -Mode Install -AutoElevate -ResultPath `"$Script:HelperInstallResultPath`""
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0 -or -not (Test-HelperAvailableFromTray)) {
            $installResult = $null
            if (Test-Path -LiteralPath $Script:HelperInstallResultPath) {
                try { $installResult = Get-Content -LiteralPath $Script:HelperInstallResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $installResult = $null }
            }
            $reason = Get-HelperInstallFailureMessage -Result $installResult -ExitCode $process.ExitCode
            Write-MonitorLog -Level 'ERROR' -Message "Helper 未就绪：$reason"
            $message = "当前高权限步骤尚未执行。`r`n`r`n原因：$reason`r`n`r`n请重新执行并在 Windows UAC 窗口中点【是】；如果不想安装 Helper，可在权限选择窗口点【否】，仅为本次操作授权。`r`n`r`n此前已经成功完成的普通网络恢复不会被回滚。"
            [System.Windows.Forms.MessageBox]::Show($message, 'Helper 未就绪', 'OK', 'Warning') | Out-Null
            return 'Cancel'
        }
        return 'Helper'
    }
    catch {
        Write-MonitorLog -Level 'ERROR' -Message "安装 Helper 失败：$($_.Exception.Message)"
        return 'Cancel'
    }
}

function Start-RepairAction {
    param(
        [string]$RepairMode,
        [string]$KeepClientId = '',
        [string[]]$TargetClientIds = @(),
        [string]$ProxyEndpoint = '',
        [string]$ProxyProtocol = 'auto',
        [bool]$RequiresPrivilege = $false,
        [bool]$TrackRepair = $false
    )
    $strategy = if ($RequiresPrivilege) { Get-PrivilegeStrategy } else { 'Normal' }
    if ($strategy -eq 'Cancel') { return $null }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$RepairPath`" -Mode $RepairMode -Force -UserConfirmed"
    if ($strategy -eq 'ElevateOnce') { $arguments += ' -AutoElevate' }
    if ($RepairMode -in @('EmergencyDirect','StopAllClients')) {
        $arguments += ' -AutoElevate'
        Remove-Item -LiteralPath $Script:RepairResultPath -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($KeepClientId)) { $arguments += " -KeepClient `"$KeepClientId`"" }
    if (@($TargetClientIds).Count -gt 0) { $arguments += " -TargetClientIds `"$($TargetClientIds -join ',')`"" }
    if (-not [string]::IsNullOrWhiteSpace($ProxyEndpoint)) { $arguments += " -ProxyEndpoint `"$ProxyEndpoint`"" }
    if ($ProxyProtocol -ne 'auto') { $arguments += " -ProxyProtocol $ProxyProtocol" }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
    if ($TrackRepair) {
        $Script:PendingRepair = [pscustomobject]@{
            mode=$RepairMode; process=$process; targetClientIds=@($TargetClientIds); startedAt=Get-Date; promptedTun=$false
            orphanPorts=$(if($null -ne $Script:LastReport){@($Script:LastReport.portOwners | Where-Object { $null -eq $_.PSObject.Properties['UiRunning'] -or -not [bool]$_.UiRunning } | Select-Object ClientId,Client,Port,Pid,Process)}else{@()})
        }
    }
    if ($RepairMode -in @('EmergencyDirect','StopAllClients')) {
        Write-StructuredEvent -Type 'EmergencyCleanupStarted' -Title '一键清场已开始' -Message '正在退出全部已知代理并恢复普通网络。' -Data ([pscustomobject]@{ detectedClients=$(if($null -ne $Script:LastReport){@($Script:LastReport.clients | Where-Object {$_.Running} | Select-Object -ExpandProperty Id)}else{@()}) })
    }
    Write-MonitorLog -Level 'INFO' -Message "已启动修复动作：$RepairMode $(if($KeepClientId){"Keep=$KeepClientId"}else{''})"
    return $process
}

function Confirm-RepairAction {
    param([string]$Title, [string]$Message)
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Get-ClientDisplayState {
    param($Client, $Report)

    $systemOwnerId = if ($null -ne $Report.owners.systemProxy) { [string]$Report.owners.systemProxy.ClientId } else { '' }
    $tunOwnerIds = @($Report.owners.tun | Where-Object { $_.ClientId -ne 'unknown' } | Select-Object -ExpandProperty ClientId -Unique)
    $diagnosisOwnerIds = if ($null -ne $Report.diagnosis) { @($Report.diagnosis.ownerIds) } else { @() }
    $isOwner = ($systemOwnerId -eq [string]$Client.Id -or $tunOwnerIds -contains [string]$Client.Id -or $diagnosisOwnerIds -contains [string]$Client.Id)
    $hasUi = (@($Client.UiProcesses).Count -gt 0)
    $hasCore = (@($Client.CoreProcesses).Count -gt 0 -or @($Client.CoreListeners).Count -gt 0)
    $hasHelper = (@($Client.HelperProcesses).Count -gt 0)
    $hasRunningService = (@($Client.Services | Where-Object { $_.Status -eq 'Running' }).Count -gt 0)
    $installed = ($Client.PSObject.Properties.Name -contains 'Installed' -and [bool]$Client.Installed)

    if ($isOwner) {
        if ($hasUi) { return [pscustomobject]@{ Label='当前正在代理'; Rank=0 } }
        if ($hasCore) { return [pscustomobject]@{ Label='当前正在代理，界面未运行'; Rank=0 } }
        return [pscustomobject]@{ Label='当前正在代理'; Rank=0 }
    }
    if ($hasUi) { return [pscustomobject]@{ Label='客户端已打开，但未接管'; Rank=1 } }
    if ($hasCore) { return [pscustomobject]@{ Label='核心仍在后台，但未接管'; Rank=2 } }
    if ($hasHelper -or $hasRunningService) { return [pscustomobject]@{ Label='只有后台服务，未接管'; Rank=3 } }
    if ($installed) { return [pscustomobject]@{ Label='已安装，未运行'; Rank=4 } }
    return [pscustomobject]@{ Label='未确认安装状态'; Rank=5 }
}

function Show-SafeSwitchSelectionDialog {
    param($Report)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '切换或只保留一个代理软件'
    $form.Width = 620
    $form.Height = 430
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Left = 18; $label.Top = 18; $label.Width = 570; $label.Height = 42
    $label.Text = '选择准备保留的代理。“当前正在代理”才表示流量经过它；客户端已打开或后台服务运行，不代表已经接管网络。'
    $form.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Left = 18; $combo.Top = 67; $combo.Width = 570
    $combo.DropDownStyle = 'DropDownList'
    $combo.DisplayMember = 'Name'; $combo.ValueMember = 'Id'
    [void]$combo.Items.Add([pscustomobject]@{ Id='__direct__'; Name='只恢复普通网络，不保留代理客户端' })
    $candidates = @($Report.clients | Where-Object { $_.Running -or $_.Installed })
    if ($candidates.Count -eq 0) { $candidates = @($Report.clients) }
    $displayCandidates = @($candidates | ForEach-Object {
        $state = Get-ClientDisplayState -Client $_ -Report $Report
        [pscustomobject]@{ Id=[string]$_.Id; Name="$($_.Name)（$($state.Label)）"; Rank=[int]$state.Rank }
    } | Sort-Object Rank, Name)
    foreach ($client in $displayCandidates) {
        [void]$combo.Items.Add($client)
    }

    $details = New-Object System.Windows.Forms.TextBox
    $details.Left = 18; $details.Top = 110; $details.Width = 570; $details.Height = 225
    $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $details.Text = "当前真正代理：$($Report.summary.effectiveOwner)`r`n系统代理：$($Report.summary.systemProxyStatus)`r`nTUN：$($Report.summary.tunOwner)`r`n`r`n说明：后台 Helper 服务只是等待高权限命令，不等于流量正在经过它。`r`n`r`n选择目标后，将停止其他客户端的 UI、核心、后台服务和明确归属的 TUN，并清除旧的本地代理环境变量。"
    $form.Controls.Add($details)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '下一步'; $ok.Left = 402; $ok.Top = 350; $ok.Width = 88; $ok.DialogResult = 'OK'
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.Left = 500; $cancel.Top = 350; $cancel.Width = 88; $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($combo); $form.Controls.Add($ok); $form.Controls.Add($cancel)
    $form.AcceptButton = $ok; $form.CancelButton = $cancel

    $settings = Get-MonitorSettings
    $selectedIndex = 0
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
        if ([string]$combo.Items[$i].Id -eq [string]$settings.preferredClientId) { $selectedIndex = $i; break }
    }
    $combo.SelectedIndex = $selectedIndex
    $result = $form.ShowDialog()
    $selected = if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $combo.SelectedItem } else { $null }
    $form.Dispose()
    return $selected
}

function Get-EnvironmentRepairSummary {
    param($Report)
    $targets = @($Report.environmentProxies | Where-Object {
        $_.Name -in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') -and $null -ne $_.Endpoint
    } | ForEach-Object { "$($_.Scope)/$($_.Name)=$($_.Value)" })
    if ($targets.Count -eq 0) { return '未发现需要清理的本地代理环境变量。' }
    return "将清理以下本地代理环境变量：`r`n- $($targets -join "`r`n- ")`r`n修改只影响新启动的程序。"
}

function Convert-HealthStatusForDisplay {
    param([string]$Status)
    switch ($Status) {
        'Healthy' { return '正常' }
        'Failed' { return '失败' }
        'Degraded' { return '异常' }
        'NotTested' { return '未检测' }
        'Unknown' { return '未确认' }
        default { if ([string]::IsNullOrWhiteSpace($Status)) { return '未确认' }; return $Status }
    }
}

function Get-NetworkStatusDialogModel {
    param($State)
    $hasRisk = ([int]$State.conflictCount -gt 0)
    $riskLines = New-Object System.Collections.Generic.List[string]
    foreach ($rawConflict in @($State.conflicts)) {
        $parts = ([string]$rawConflict) -split '\|', 3
        if ($parts.Count -eq 3) { $riskLines.Add("$($parts[0])：$($parts[2])") }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$rawConflict)) { $riskLines.Add([string]$rawConflict) }
    }
    if ($hasRisk -and $riskLines.Count -eq 0) { $riskLines.Add('检测到多个代理组件同时运行，切换客户端时可能发生冲突。') }

    $headline = if ($hasRisk) { "发现 $($State.conflictCount) 个可能导致切换失败的问题" } else { '当前没有发现代理接管冲突' }
    $recommendation = if ($hasRisk) {
        '如果你不确定应该关闭哪个客户端，建议一键退出全部代理并恢复普通网络；确认网页能打开后，只重新打开一个代理客户端。'
    }
    else { [string]$State.diagnosisAction }
    $statusRows = @(
        [pscustomobject]@{ Name='当前主要代理'; Value=[string]$State.effectiveOwner }
        [pscustomobject]@{ Name='诊断结果'; Value=[string]$State.diagnosisTitle }
        [pscustomobject]@{ Name='Windows 代理'; Value=$(if($State.systemProxyEnabled){'已开启'}else{'已关闭'}) }
        [pscustomobject]@{ Name='Windows 代理来自'; Value=$(if($State.systemProxyOwner){[string]$State.systemProxyOwner}else{'未识别或没有使用'}) }
        [pscustomobject]@{ Name='Windows 代理地址'; Value=$(if($State.systemProxyServer){[string]$State.systemProxyServer}else{'未设置'}) }
        [pscustomobject]@{ Name='虚拟网卡代理（TUN）'; Value=$(if(@($State.tunOwners).Count){$State.tunOwners -join '、'}else{'未发现'}) }
        [pscustomobject]@{ Name='代理联网'; Value=(Convert-HealthStatusForDisplay $State.proxyStatus) }
        [pscustomobject]@{ Name='绕过系统代理'; Value=(Convert-HealthStatusForDisplay $State.directStatus) }
        [pscustomobject]@{ Name='DNS'; Value=(Convert-HealthStatusForDisplay $State.dnsStatus) }
    )
    $detailLines = New-Object System.Collections.Generic.List[string]
    $detailLines.Add('诊断说明')
    $detailLines.Add("- $([string]$State.diagnosisMessage)")
    $detailLines.Add('')
    $detailLines.Add('发现的问题')
    if ($riskLines.Count -gt 0) {
        for ($index = 0; $index -lt $riskLines.Count; $index++) {
            $detailLines.Add("$($index + 1). $($riskLines[$index])")
        }
    }
    else {
        $detailLines.Add('- 未发现需要处理的问题。')
    }
    $detailLines.Add('')
    $detailLines.Add('建议')
    $detailLines.Add("- $recommendation")
    $body = $detailLines -join "`r`n"
    return [pscustomobject]@{
        HasRisk = $hasRisk
        Headline = $headline
        StatusRows = $statusRows
        RiskLines = $riskLines.ToArray()
        Recommendation = $recommendation
        Body = $body
        RepairButtonText = '退出全部代理并恢复普通网络'
        CloseButtonText = $(if($hasRisk){'暂不处理'}else{'关闭'})
    }
}

function Show-NetworkStatusDialog {
    param($State)
    $model = Get-NetworkStatusDialogModel -State $State
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '断网急救 - 网络状态'
    $form.Width = 760
    $form.Height = 690
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.AutoScaleMode = 'Dpi'
    $form.TopMost = $true

    $headline = New-Object System.Windows.Forms.Label
    $headline.Left = 24; $headline.Top = 20; $headline.Width = 690; $headline.Height = 46
    $headline.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $headline.ForeColor = if ($model.HasRisk) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkGreen }
    $headline.Text = $model.Headline

    $statusList = New-Object System.Windows.Forms.ListView
    $statusList.Left = 24; $statusList.Top = 76; $statusList.Width = 690; $statusList.Height = 270
    $statusList.View = [System.Windows.Forms.View]::Details
    $statusList.FullRowSelect = $true
    $statusList.GridLines = $true
    $statusList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
    $statusList.HideSelection = $false
    $statusList.MultiSelect = $false
    $statusList.TabStop = $false
    $statusList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    [void]$statusList.Columns.Add('项目', 205)
    [void]$statusList.Columns.Add('当前状态', 455)
    foreach ($row in @($model.StatusRows)) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Name)
        [void]$item.SubItems.Add([string]$row.Value)
        [void]$statusList.Items.Add($item)
    }

    $details = New-Object System.Windows.Forms.TextBox
    $details.Left = 24; $details.Top = 360; $details.Width = 690; $details.Height = 230
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = 'Vertical'
    $details.BorderStyle = 'FixedSingle'
    $details.BackColor = [System.Drawing.Color]::White
    $details.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $details.Text = $model.Body
    $details.TabStop = $false

    $close = New-Object System.Windows.Forms.Button
    $close.Text = $model.CloseButtonText
    $close.Left = 608; $close.Top = 604; $close.Width = 106; $close.Height = 38
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $repair = New-Object System.Windows.Forms.Button
    $repair.Text = $model.RepairButtonText
    $repair.Left = 334; $repair.Top = 604; $repair.Width = 260; $repair.Height = 38
    $repair.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $repair.Visible = [bool]$model.HasRisk
    $repair.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $repair.ForeColor = [System.Drawing.Color]::White
    $repair.FlatStyle = 'Flat'

    $form.Controls.Add($headline)
    $form.Controls.Add($statusList)
    $form.Controls.Add($details)
    $form.Controls.Add($repair)
    $form.Controls.Add($close)
    $form.CancelButton = $close
    $form.AcceptButton = $close
    try {
        $result = $form.ShowDialog()
        if ($model.HasRisk -and $result -eq [System.Windows.Forms.DialogResult]::OK) { return 'Repair' }
        return 'Close'
    }
    finally { $form.Dispose() }
}

function Get-EmergencyCleanupSummary {
    param($Report)
    if ($null -eq $Report) { return '将扫描并退出全部已识别的代理组件。' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($client in @($Report.clients)) {
        $parts = New-Object System.Collections.Generic.List[string]
        if (@($client.UiProcesses).Count -gt 0) { $parts.Add("界面 $(@($client.UiProcesses).Count) 个") }
        if (@($client.CoreProcesses).Count -gt 0) { $parts.Add("核心 $(@($client.CoreProcesses).Count) 个") }
        if (@($client.HelperProcesses).Count -gt 0) { $parts.Add("Helper 进程 $(@($client.HelperProcesses).Count) 个") }
        $runningServices = @($client.Services | Where-Object { $_.Status -eq 'Running' })
        if ($runningServices.Count -gt 0) { $parts.Add("后台服务 $($runningServices.Count) 个") }
        if ($parts.Count -gt 0) { $lines.Add("$($client.Name)：$($parts -join '、')") }
    }
    foreach ($owner in @($Report.portOwners)) {
        $lines.Add("端口：$($owner.Process)（PID $($owner.Pid)）占用 $($owner.Port)")
    }
    foreach ($tun in @($Report.owners.tun | Where-Object { $_.ClientId -ne 'unknown' })) {
        $lines.Add("TUN：$($tun.Client) / $($tun.InterfaceAlias)")
    }
    if ($lines.Count -eq 0) { $lines.Add('未发现活动代理进程；仍会检查系统代理、环境变量、服务、TUN、路由和 DNS 残留') }
    return "准备处理：`r`n- $($lines -join "`r`n- ")"
}

function Invoke-EmergencyCleanupFromTray {
    $summary = Get-EmergencyCleanupSummary -Report $Script:LastReport
    if (Confirm-RepairAction '一键退出全部代理并恢复普通网络' "$summary`r`n`r`n将先请求客户端正常退出，最多等待 5 秒；随后停止已知服务并精确清理残留核心、TUN、198.18 路由、本地代理环境变量和代理 DNS。未知进程、未知网卡、未知路由和企业 PAC 不会被修改。`r`n`r`n当前代理连接会立即中断。是否继续？") {
        [void](Start-RepairAction -RepairMode 'EmergencyDirect' -TrackRepair $true)
    }
}

function Invoke-SafeSwitchWizard {
    if ($null -eq $Script:LastReport) {
        if ($null -eq $Script:AsyncScan) { Start-AsyncMonitorScan }
        Show-MonitorNotification -Event ([pscustomobject]@{ Title='正在检查网络'; Text='状态准备完成后再打开切换工具，托盘菜单不会被阻塞。'; Icon='Info' })
        return
    }
    $selected = Show-SafeSwitchSelectionDialog -Report $Script:LastReport
    if ($null -eq $selected) { return }
    if ($selected.Id -eq '__direct__') {
        $summary = Get-EnvironmentRepairSummary -Report $Script:LastReport
        if (Confirm-RepairAction '恢复普通网络' "将关闭 Windows 系统代理并清理失效的本地 WinHTTP 和代理环境变量。`r`n`r`n$summary`r`n`r`n不会自动结束客户端；若仍发现 TUN，稍后会单独请求确认。是否继续？") {
            [void](Start-RepairAction -RepairMode 'RestoreDirect' -TrackRepair $true)
        }
        return
    }
    $target = $Script:LastReport.clients | Where-Object { $_.Id -eq $selected.Id } | Select-Object -First 1
    if ($null -eq $target) { return }
    $otherRunning = @($Script:LastReport.clients | Where-Object {
        $_.Id -ne $target.Id -and ($_.Running -or @($_.Services | Where-Object { $_.Status -eq 'Running' }).Count -gt 0)
    } | ForEach-Object {
        $state = Get-ClientDisplayState -Client $_ -Report $Script:LastReport
        "$($_.Name)（$($state.Label)）"
    })
    $ports = @($Script:LastReport.portOwners | Where-Object { $_.ClientId -ne $target.Id } | ForEach-Object { "$($_.Client) 的 $($_.Process)（PID $($_.Pid)）占用 $($_.Port)" })
    $details = "准备保留：$($target.Name)`r`n将停止的其他组件：$(if($otherRunning.Count){$otherRunning -join '、'}else{'未发现其他活动组件'})"
    if ($ports.Count -gt 0) { $details += "`r`n当前端口占用：$($ports -join '；')" }
    $details += "`r`n`r`n$(Get-EnvironmentRepairSummary -Report $Script:LastReport)"
    if (-not (Confirm-RepairAction "切换到 $($target.Name)" "$details`r`n`r`n清理后请回 $($target.Name) 手动选择节点并连接。是否继续？")) { return }
    $process = Start-RepairAction -RepairMode 'PrepareSwitch' -KeepClientId ([string]$target.Id) -RequiresPrivilege $true
    if ($null -eq $process) { return }
    $Script:PendingSwitch = [pscustomobject]@{
        targetId=[string]$target.Id; targetName=[string]$target.Name; targetPorts=@($target.DefaultProxyPorts)
        oldPortOwners=@($Script:LastReport.portOwners | Where-Object { $_.ClientId -ne $target.Id } | Select-Object ClientId,Client,Port,Pid,Process,StartTimeUtc)
        process=$process; stage='Cleaning'; startedAt=Get-Date; deadline=(Get-Date).AddMinutes(5)
    }
    Write-StructuredEvent -Type 'SafeSwitchStarted' -Title '安全切换已开始' -Message "准备切换到 $($target.Name)，正在释放其他网络 Owner。" -Data ([pscustomobject]@{ targetClientId=$target.Id; targetClient=$target.Name })
}

function Invoke-ApplicationPathRepair {
    if ($null -eq $Script:LastReport) {
        if ($null -eq $Script:AsyncScan) { Start-AsyncMonitorScan }
        Show-MonitorNotification -Event ([pscustomobject]@{ Title='正在检查联网路径'; Text='检查完成后再打开此工具。'; Icon='Info' })
        return
    }
    $report = $Script:LastReport
    $currentEndpoint = if ($report.systemProxy.Enabled -and $null -ne $report.systemProxy.Endpoint) { [string]$report.systemProxy.Endpoint.Text } else { '' }
    $owner = $report.owners.systemProxy
    $client = if ($null -ne $owner) { $report.clients | Where-Object { $_.Id -eq $owner.ClientId } | Select-Object -First 1 } else { $null }
    $canSync = (-not [string]::IsNullOrWhiteSpace($currentEndpoint) -and $null -ne $client -and @($client.ProxyCapabilities | Where-Object { $_ -in @('http','mixed') }).Count -gt 0)
    $environmentText = Get-EnvironmentRepairSummary -Report $report
    if ($canSync) {
        $protocol = if (@($client.ProxyCapabilities) -contains 'mixed') { 'mixed' } else { 'http' }
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "当前 Windows 代理：$($client.Name) / $currentEndpoint`r`n`r`n$environmentText`r`n`r`n选择【是】：让 Codex/终端跟随当前代理。`r`n选择【否】：清除旧代理环境变量，改为跟随系统网络。`r`n选择【取消】：不修改。",
            '修复应用联网路径', 'YesNoCancel', 'Question'
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Start-RepairAction -RepairMode 'SyncApplicationProxy' -ProxyEndpoint $currentEndpoint -ProxyProtocol $protocol -TrackRepair $true)
        }
        elseif ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            [void](Start-RepairAction -RepairMode 'ClearApplicationProxy' -TrackRepair $true)
        }
    }
    else {
        if (Confirm-RepairAction '清除旧应用代理' "当前没有可安全同步的 HTTP/Mixed 本地代理。`r`n`r`n$environmentText`r`n`r`n是否清除这些旧环境变量？") {
            [void](Start-RepairAction -RepairMode 'ClearApplicationProxy' -TrackRepair $true)
        }
    }
}

function Update-PendingRepairAndSwitch {
    param($Report, $State)
    if ($null -ne $Script:PendingRepair) {
        $pending = $Script:PendingRepair
        if ($pending.process.HasExited) {
            $exitCode = $pending.process.ExitCode
            $Script:PendingRepair = $null
            if ($pending.mode -in @('EmergencyDirect','StopAllClients')) {
                $result = $null
                try {
                    if (Test-Path -LiteralPath $Script:RepairResultPath) { $result = Get-Content -LiteralPath $Script:RepairResultPath -Raw -Encoding UTF8 | ConvertFrom-Json }
                }
                catch { Write-MonitorLog -Level 'ERROR' -Message "读取清场结果失败：$($_.Exception.Message)" }
                $completed = ($exitCode -eq 0 -and $null -ne $result -and $result.status -eq 'Completed' -and [bool]$result.systemProxyClosed -and [bool]$result.proxyResidueCleaned -and [bool]$result.directConfirmed)
                if ($completed) {
                    Write-StructuredEvent -Type 'EmergencyCleanupCompleted' -Title '一键清场完成' -Message '系统代理已关闭、代理残留已清理、普通网络已确认恢复。' -Data $result
                    if (@($pending.orphanPorts).Count -gt 0) {
                        Write-StructuredEvent -Type 'OrphanCoreReleased' -Title '孤儿核心已释放' -Message '界面退出后仍占用代理端口的已知核心已经释放。' -Data @($pending.orphanPorts)
                    }
                    Show-MonitorNotification -Event ([pscustomobject]@{ Title='普通网络已经恢复'; Text='如需代理，请只打开一个客户端。'; Icon='Info' })
                }
                else {
                    $detail = if ($null -ne $result) { [string]$result.message } else { "清场退出码为 $exitCode，未读取到完整结果。" }
                    Write-StructuredEvent -Type 'EmergencyCleanupPartial' -Title '一键清场部分完成' -Message $detail -Data $result
                    Show-MonitorNotification -Event ([pscustomobject]@{ Title='清场只完成了一部分'; Text='残留或联网失败项已写入运行记录，请稍后重试或联系排查。'; Icon='Warning' })
                }
            }
            elseif ($exitCode -ne 0) {
                Write-MonitorLog -Level 'ERROR' -Message "修复动作 $($pending.mode) 退出码为 $exitCode。"
            }
            elseif ($pending.mode -eq 'RestoreDirect' -and @($State.tunOwnerIds).Count -gt 0) {
                $ids = @($State.tunOwnerIds)
                $names = @($Report.clients | Where-Object { $ids -contains $_.Id } | Select-Object -ExpandProperty Name)
                if (Confirm-RepairAction '仍发现虚拟网卡代理' "Windows 系统代理已经关闭，但 $($names -join '、') 的 TUN 仍在接管网络。`r`n`r`n是否完整退出这些客户端并清理明确归属的 TUN？") {
                    [void](Start-RepairAction -RepairMode 'StopSelectedClients' -TargetClientIds $ids -RequiresPrivilege $true -TrackRepair $true)
                }
            }
            elseif ($pending.mode -in @('StopSelectedClients','VerifyStopSelected')) {
                $remaining = @($State.tunOwnerIds | Where-Object { @($pending.targetClientIds) -contains $_ })
                if ($remaining.Count -eq 0) {
                    Write-StructuredEvent -Type 'TunResidualCleaned' -Title 'TUN 残留已清理' -Message '用户确认的客户端 TUN 接管已经释放。' -Data ([pscustomobject]@{ clientIds=@($pending.targetClientIds) })
                }
                elseif (((Get-Date) - $pending.startedAt).TotalSeconds -lt 45) {
                    $pending.mode = 'VerifyStopSelected'
                    $Script:PendingRepair = $pending
                }
                else {
                    Write-MonitorLog -Level 'WARN' -Message "TUN 清理后仍检测到接管：$($remaining -join '、')。"
                }
            }
        }
    }

    if ($null -eq $Script:PendingSwitch) { return }
    $switch = $Script:PendingSwitch
    if ($switch.stage -eq 'Cleaning') {
        if (-not $switch.process.HasExited) { return }
        if ($switch.process.ExitCode -ne 0) {
            Write-StructuredEvent -Type 'SafeSwitchFailed' -Title '安全切换清理失败' -Message "切换到 $($switch.targetName) 时，旧客户端清理没有完整完成。" -Data ([pscustomobject]@{ exitCode=$switch.process.ExitCode })
            $Script:PendingSwitch = $null
            return
        }
        $switch.stage = 'VerifyCleanup'
        return
    }
    if ($switch.stage -eq 'VerifyCleanup') {
        $blocking = @($State.portOwners | Where-Object { $_.clientId -ne $switch.targetId -and @($switch.targetPorts) -contains $_.port })
        if ($blocking.Count -gt 0) {
            $text = @($blocking | ForEach-Object { "$($_.client) 的 $($_.process)（PID $($_.pid)）仍占用 $($_.port)" }) -join '；'
            Write-StructuredEvent -Type 'SafeSwitchFailed' -Title '目标端口仍被占用' -Message $text -Data $blocking
            Show-MonitorNotification -Event ([pscustomobject]@{ Title='切换尚未完成'; Text=$text; Icon='Warning' })
            $Script:PendingSwitch = $null
            return
        }
        if (@($switch.oldPortOwners).Count -gt 0) {
            Write-StructuredEvent -Type 'OrphanCoreReleased' -Title '旧客户端端口已经释放' -Message '切换前检测到的旧客户端核心端口已经释放。' -Data @($switch.oldPortOwners)
        }
        $switch.stage = 'WaitingForTarget'
        Show-MonitorNotification -Event ([pscustomobject]@{ Title='旧客户端已经释放'; Text="请回 $($switch.targetName) 手动选择节点并连接，断网急救将在 5 分钟内自动复核。"; Icon='Info' })
        return
    }
    if ($switch.stage -eq 'WaitingForTarget') {
        $ownsNetwork = @($State.diagnosisOwnerIds) -contains $switch.targetId
        $tunHealthy = (@($State.tunOwnerIds) -contains $switch.targetId) -and $State.directHealthy
        if ($ownsNetwork -and ($State.proxyHealthy -or $tunHealthy)) {
            Save-PreferredClient -ClientId $switch.targetId
            Write-StructuredEvent -Type 'SafeSwitchCompleted' -Title '安全切换完成' -Message "$($switch.targetName) 已成为有效网络 Owner，联网复核成功。" -Data ([pscustomobject]@{ targetClientId=$switch.targetId; targetClient=$switch.targetName })
            Show-MonitorNotification -Event ([pscustomobject]@{ Title='代理切换完成'; Text="$($switch.targetName) 已接管网络并通过联网复核。"; Icon='Info' })
            $Script:PendingSwitch = $null
            if ($State.systemProxyOwnerId -eq $switch.targetId -and $State.proxyHealthy) {
                $sync = [System.Windows.Forms.MessageBox]::Show('是否让 Codex、终端等使用环境变量的应用同步到当前代理？修改后需要重启这些应用。', '代理切换完成', 'YesNo', 'Question')
                if ($sync -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-ApplicationPathRepair }
            }
            return
        }
        if ((Get-Date) -ge $switch.deadline) {
            Write-StructuredEvent -Type 'SafeSwitchFailed' -Title '安全切换等待超时' -Message "5 分钟内未确认 $($switch.targetName) 成功接管并联网。" -Data ([pscustomobject]@{ targetClientId=$switch.targetId })
            Show-MonitorNotification -Event ([pscustomobject]@{ Title='切换尚未完成'; Text="未检测到 $($switch.targetName) 成功联网，请检查客户端连接状态。"; Icon='Warning' })
            $Script:PendingSwitch = $null
        }
    }
}

function Invoke-MonitorSelfTest {
    $Script:TestMode = $true
    try {
    $sourceText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    foreach ($menuText in @('网络状态：正在检查','一键退出全部代理并恢复普通网络','系统代理异常时自动急救：已开启','退出断网急救')) {
        if (-not $sourceText.Contains($menuText)) { throw "托盘一级菜单缺少：$menuText" }
    }
    $removedDiagnosticMenuText = '诊断报告' + '与记录'
    if ($sourceText.Contains($removedDiagnosticMenuText)) { throw '托盘仍保留已删除的诊断记录入口。' }
    if ($sourceText -match "(?m)^\s*`$restoreDirectItem\s*=\s*`$menu\.Items\.Add\('网络打不开？恢复普通上网'\)" -or $sourceText -match '(?m)^\s*\[void\]\$menu\.Items\.Add\(\$moreMenu\)') { throw '托盘仍保留旧的重复恢复入口或“更多工具”一级菜单。' }
    $legacyStateToken = '$Script:' + 'Paused'
    if ($sourceText.Contains($legacyStateToken)) { throw '已删除暂停监控功能，但脚本仍残留旧状态引用。' }
    $blockingCmdlet = 'Get-NetTCP' + 'Connection'
    if ($sourceText.Contains($blockingCmdlet)) { throw "托盘脚本仍使用可能阻塞 UI 的 $blockingCmdlet。" }
    $lockedFile = Join-Path ([IO.Path]::GetTempPath()) "network-rescue-locked-log-$PID.txt"
    [IO.File]::WriteAllText($lockedFile, 'locked')
    $lockStream = New-Object IO.FileStream($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if (Add-ContentWithRetry -Path $lockedFile -Value 'test' -Attempts 2) { throw '文件被独占时安全写入不应报告成功。' }
    }
    finally {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockedFile -Force -ErrorAction SilentlyContinue
    }
    $rotationFile = Join-Path ([IO.Path]::GetTempPath()) "network-rescue-rotation-$PID.log"
    try {
        foreach ($cycle in 1..5) {
            [IO.File]::WriteAllBytes($rotationFile, (New-Object byte[] 96))
            if (-not (Add-ContentWithRetry -Path $rotationFile -Value '0123456789' -MaxBytes 100 -ArchiveCount 3)) {
                throw '日志轮转后无法继续写入。'
            }
        }
        if (-not (Test-Path -LiteralPath "$rotationFile.3") -or (Test-Path -LiteralPath "$rotationFile.4")) {
            throw '日志轮转没有严格保留 3 份归档。'
        }
    }
    finally {
        Remove-Item -LiteralPath $rotationFile -Force -ErrorAction SilentlyContinue
        foreach ($index in 1..4) { Remove-Item -LiteralPath "$rotationFile.$index" -Force -ErrorAction SilentlyContinue }
    }
    Invoke-TrayActionSafely -ActionName '点击回调测试' -Action { throw '模拟托盘点击异常' }
    $displayReport = [pscustomobject]@{
        owners = [pscustomobject]@{ systemProxy=[pscustomobject]@{ClientId='clash_verge'}; tun=@() }
        diagnosis = [pscustomobject]@{ ownerIds=@('clash_verge') }
    }
    $ownerCoreOnly = [pscustomobject]@{ Id='clash_verge'; UiProcesses=@(); CoreProcesses=@([pscustomobject]@{Id=1}); CoreListeners=@([pscustomobject]@{Port=7890}); HelperProcesses=@(); Services=@(); Installed=$true }
    $openedNotOwner = [pscustomobject]@{ Id='longmao'; UiProcesses=@([pscustomobject]@{Id=2}); CoreProcesses=@([pscustomobject]@{Id=3}); CoreListeners=@(); HelperProcesses=@(); Services=@(); Installed=$true }
    $helperOnly = [pscustomobject]@{ Id='globalcloud'; UiProcesses=@(); CoreProcesses=@(); CoreListeners=@(); HelperProcesses=@([pscustomobject]@{Id=4}); Services=@([pscustomobject]@{Status='Running'}); Installed=$true }
    $installedOnly = [pscustomobject]@{ Id='v2cloud'; UiProcesses=@(); CoreProcesses=@(); CoreListeners=@(); HelperProcesses=@(); Services=@(); Installed=$true }
    if ((Get-ClientDisplayState $ownerCoreOnly $displayReport).Label -ne '当前正在代理，界面未运行') { throw '当前核心 Owner 的新手状态文案错误。' }
    if ((Get-ClientDisplayState $openedNotOwner $displayReport).Label -ne '客户端已打开，但未接管') { throw '已打开但未接管的状态文案错误。' }
    if ((Get-ClientDisplayState $helperOnly $displayReport).Label -ne '只有后台服务，未接管') { throw 'Helper-only 状态被误报为正在运行。' }
    if ((Get-ClientDisplayState $installedOnly $displayReport).Label -ne '已安装，未运行') { throw '仅安装状态文案错误。' }
    $helperFailure = [pscustomobject]@{ stage='创建 Helper 服务'; message='测试失败'; success=$false }
    if ((Get-HelperInstallFailureMessage -Result $helperFailure -ExitCode 1) -notlike '*创建 Helper 服务*测试失败*') { throw 'Helper 详细错误没有显示安装阶段和原因。' }
    if ((Get-HelperInstallFailureMessage -Result $null -ExitCode 1223) -notlike '*取消*') { throw 'UAC 取消原因没有被识别。' }
    $base = [pscustomobject]@{
        observedAt = (Get-Date).ToString('o'); effectiveOwner = 'Clash Verge'; systemProxyEnabled = $true
        systemProxyServer = '127.0.0.1:7890'; systemProxyOwner = 'Clash Verge'; systemProxyOwnerId = 'clash_verge'; tunOwners = @()
        tunOwnerIds = @(); systemProxyIsLocal = $true; staleSystemProxy = $false; conflictCount = 0; conflicts = @(); coreClients = @('Clash Verge'); proxyGuardClients = @(); warningCount = 0
        diagnosisCode='HealthySingleOwner'; diagnosisTitle='代理接管正常'; diagnosisMessage='正常'; diagnosisAction='无需操作'; diagnosisOwnerIds=@('clash_verge'); diagnosisFindings=@()
        directStatus='Healthy'; directHealthy=$true; proxyStatus='Healthy'; proxyHealthy=$true; proxyFailureCandidate=$false; dnsStatus='Healthy'; portOwners=@(); environmentProxies=@()
    }
    $conflict = [pscustomobject]@{
        observedAt = (Get-Date).ToString('o'); effectiveOwner = '多 Owner 冲突：Clash Verge、龙猫云 Lite'; systemProxyEnabled = $true
        systemProxyServer = '127.0.0.1:7890'; systemProxyOwner = 'Clash Verge'; systemProxyOwnerId = 'clash_verge'; tunOwners = @('龙猫云 Lite|lmclient|198.18.0.1')
        tunOwnerIds = @('longmao')
        systemProxyIsLocal = $true; staleSystemProxy = $false; conflictCount = 1; conflicts = @('高风险|系统代理/TUN|系统代理属于 Clash Verge，TUN 属于龙猫云 Lite。')
        coreClients = @('Clash Verge', '龙猫云 Lite'); proxyGuardClients = @(); warningCount = 0
        diagnosisCode='MultiOwnerConflict'; diagnosisTitle='多个代理客户端正在同时接管'; diagnosisMessage='冲突'; diagnosisAction='安全切换'; diagnosisOwnerIds=@('clash_verge','longmao'); diagnosisFindings=@([pscustomobject]@{code='TunResidual';severity='高风险';message='测试';action='测试'})
        directStatus='Healthy'; directHealthy=$true; proxyStatus='Healthy'; proxyHealthy=$true; proxyFailureCandidate=$false; dnsStatus='Healthy'; portOwners=@(); environmentProxies=@()
    }
    $healthyStatusModel = Get-NetworkStatusDialogModel -State $base
    if ($healthyStatusModel.HasRisk -or $healthyStatusModel.CloseButtonText -ne '关闭') { throw '无冲突状态窗口仍显示修复入口。' }
    if (@($healthyStatusModel.StatusRows).Count -ne 9 -or @($healthyStatusModel.StatusRows | Where-Object { $_.Name -eq 'Windows 代理地址' -and $_.Value -eq '127.0.0.1:7890' }).Count -ne 1) { throw '网络状态没有生成清晰的项目列表。' }
    $conflictStatusModel = Get-NetworkStatusDialogModel -State $conflict
    if (-not $conflictStatusModel.HasRisk -or $conflictStatusModel.RepairButtonText -ne '退出全部代理并恢复普通网络') { throw '冲突状态窗口缺少一键解决入口。' }
    if ($conflictStatusModel.Body -notlike '*1. 高风险：系统代理属于 Clash Verge，TUN 属于龙猫云 Lite*' -or $conflictStatusModel.Body -notmatch "`r`n" -or $conflictStatusModel.CloseButtonText -ne '暂不处理') { throw '冲突详情列表或暂不处理入口文案错误。' }
    if ((Get-StateFingerprint $base) -eq (Get-StateFingerprint $conflict)) { throw '不同状态生成了相同指纹。' }
    $event = Get-ChangeEvent -OldState $base -NewState $conflict
    if ($event.Type -ne 'ConflictDetected') { throw "冲突事件分类错误：$($event.Type)" }
    $disabled = $base.PSObject.Copy()
    $disabled.systemProxyEnabled = $false
    $disabled.systemProxyOwner = ''
    $disabled.systemProxyOwnerId = ''
    $disabled.coreClients = @('Clash Verge', '龙猫云 Lite')
    $disabled.conflictCount = 1
    $disabled.conflicts = @('中风险|后台核心|多个客户端保留核心或监听端口。')
    $disabledEvent = Get-ChangeEvent -OldState $base -NewState $disabled
    if ($disabledEvent.Type -ne 'SystemProxyUnexpectedlyDisabled') { throw "系统代理意外关闭事件分类错误：$($disabledEvent.Type)" }

    $restoreOld = $base.PSObject.Copy()
    $restoreOld.systemProxyOwner = '龙猫云 Lite'
    $restoreOld.systemProxyOwnerId = 'longmao'
    $restoreOld.coreClients = @('Clash Party', '龙猫云 Lite')
    $restoreOld.portOwners = @([pscustomobject]@{clientId='longmao';client='龙猫云 Lite';port=7890;pid=17828;process='lmclientCore';startTimeUtc='2026-07-15T14:00:14Z';uiRunning=$true})
    $restoreNew = $restoreOld.PSObject.Copy()
    $restoreNew.systemProxyEnabled = $false
    $restoreNew.systemProxyOwner = ''
    $restoreNew.systemProxyOwnerId = ''
    $restoreNew.coreClients = @('龙猫云 Lite')
    $candidate = Get-SystemProxyAutoRestoreCandidate -OldState $restoreOld -NewState $restoreNew
    if ($null -eq $candidate -or $candidate.OwnerId -ne 'longmao' -or $candidate.ExpectedPid -ne 17828 -or @($candidate.DisappearedClients) -notcontains 'Clash Party') { throw '其他客户端退出误关主代理时，没有生成安全恢复候选。' }
    $manualOffOld = $restoreOld.PSObject.Copy()
    $manualOffOld.coreClients = @('龙猫云 Lite')
    if ($null -ne (Get-SystemProxyAutoRestoreCandidate -OldState $manualOffOld -NewState $restoreNew)) { throw '用户单独关闭系统代理时被误判为其他客户端退出误关。' }
    $ownerExited = $restoreNew.PSObject.Copy()
    $ownerExited.coreClients = @()
    $ownerExited.portOwners = @()
    if ($null -ne (Get-SystemProxyAutoRestoreCandidate -OldState $restoreOld -NewState $ownerExited)) { throw '主代理核心退出时仍生成了自动重开候选。' }

    $Script:StableState = $null
    $Script:StableFingerprint = ''
    $Script:PendingFingerprint = ''
    $Script:PendingCount = 0
    Submit-MonitorSample -State $base | Out-Null
    Submit-MonitorSample -State $conflict | Out-Null
    if ($Script:StableState.effectiveOwner -ne 'Clash Verge') { throw '防抖第一次采样不应接受变化。' }
    Submit-MonitorSample -State $conflict | Out-Null
    if ($Script:StableState.effectiveOwner -notmatch '多 Owner') { throw '防抖达到阈值后未接受变化。' }
    $stale = $base.PSObject.Copy()
    $stale.systemProxyServer = '127.0.0.1:65534'
    $stale.systemProxyOwner = ''
    $stale.systemProxyOwnerId = ''
    $stale.staleSystemProxy = $true
    $stale.conflictCount = 1
    $stale.conflicts = @('紧急|系统代理|系统代理指向 127.0.0.1:65534，但端口没有已识别监听者。')
    $Script:StaleProxyServer = ''
    $Script:StaleProxyCount = 0
    1..$AutoRecoverySamples | ForEach-Object { Submit-AutoRecoverySample -State $stale | Out-Null }
    if ($Script:StaleProxyCount -ne $AutoRecoverySamples) { throw '自动急救确认计数错误。' }

    $originalPathHealthScript = $Script:PathHealthScript
    $slowProbeScript = Join-Path ([IO.Path]::GetTempPath()) "network-rescue-slow-probe-$PID.ps1"
    try {
        @'
param([string]$ProxyEndpoint, [switch]$SkipDirect, [switch]$SkipProxy, [int]$TimeoutSeconds, [switch]$PassThru)
Start-Sleep -Milliseconds 1200
[pscustomobject]@{
    schemaVersion=2
    direct=[pscustomobject]@{ healthy=$true; status='Healthy' }
    proxy=[pscustomobject]@{ healthy=$true; status='Healthy'; pid=17828; process='lmclientCore' }
}
'@ | Set-Content -LiteralPath $slowProbeScript -Encoding UTF8
        $Script:PathHealthScript = $slowProbeScript
        $Script:AsyncDirectProbe = $null
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $started = Start-AsyncDirectInternetTest -ProxyServer '127.0.0.1:65534'
        $stopwatch.Stop()
        if (-not $started -or $stopwatch.ElapsedMilliseconds -ge 500) { throw "后台普通网络探测启动阻塞 UI：$($stopwatch.ElapsedMilliseconds)ms。" }
        $deadline = (Get-Date).AddSeconds(5)
        while ($null -ne $Script:AsyncDirectProbe -and -not $Script:AsyncDirectProbe.Async.IsCompleted -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        $probeResult = Complete-AsyncDirectInternetTest
        if ($null -eq $probeResult -or -not $probeResult.Healthy) { throw '后台普通网络探测结果错误。' }
        $Script:AsyncSystemProxyRestoreProbe = $null
        $started = Start-AsyncSystemProxyRestoreTest -Candidate $candidate
        if (-not $started) { throw '后台系统代理恢复复核没有启动。' }
        $deadline = (Get-Date).AddSeconds(5)
        while ($null -ne $Script:AsyncSystemProxyRestoreProbe -and -not $Script:AsyncSystemProxyRestoreProbe.Async.IsCompleted -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        $restoreProbeResult = Complete-AsyncSystemProxyRestoreTest
        if ($null -eq $restoreProbeResult -or -not $restoreProbeResult.Healthy -or $restoreProbeResult.Pid -ne 17828 -or $restoreProbeResult.Candidate.OwnerId -ne 'longmao') { throw '后台系统代理恢复复核结果错误。' }
    }
    finally {
        if ($null -ne $Script:AsyncDirectProbe) {
            try { $Script:AsyncDirectProbe.PowerShell.Stop() } catch {}
            try { $Script:AsyncDirectProbe.PowerShell.Dispose() } catch {}
            $Script:AsyncDirectProbe = $null
        }
        if ($null -ne $Script:AsyncSystemProxyRestoreProbe) {
            try { $Script:AsyncSystemProxyRestoreProbe.PowerShell.Stop() } catch {}
            try { $Script:AsyncSystemProxyRestoreProbe.PowerShell.Dispose() } catch {}
            $Script:AsyncSystemProxyRestoreProbe = $null
        }
        $Script:PathHealthScript = $originalPathHealthScript
        Remove-Item -LiteralPath $slowProbeScript -Force -ErrorAction SilentlyContinue
    }

    $originalScannerPath = $Script:ScannerPath
    $slowScannerScript = Join-Path ([IO.Path]::GetTempPath()) "network-rescue-slow-scanner-$PID.ps1"
    $heartbeatTimer = $null
    try {
        @'
param([string]$AdapterPath, [switch]$PassThru, [switch]$NoWriteReport, [switch]$Quiet)
Start-Sleep -Milliseconds 1500
[pscustomobject]@{ summary='slow-test' }
'@ | Set-Content -LiteralPath $slowScannerScript -Encoding UTF8
        $Script:ScannerPath = $slowScannerScript
        $Script:AsyncScan = $null
        Add-Type -AssemblyName System.Windows.Forms
        $Script:SelfTestUiHeartbeat = 0
        $heartbeatTimer = New-Object System.Windows.Forms.Timer
        $heartbeatTimer.Interval = 50
        $heartbeatTimer.add_Tick({ $Script:SelfTestUiHeartbeat++ })
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Start-AsyncMonitorScan
        $startElapsed = $stopwatch.ElapsedMilliseconds
        $heartbeatTimer.Start()
        while ($stopwatch.ElapsedMilliseconds -lt 700) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }
        $heartbeatTimer.Stop()
        $stopwatch.Stop()
        if ($startElapsed -ge 500) { throw "后台完整扫描启动阻塞 UI：${startElapsed}ms。" }
        if ($Script:SelfTestUiHeartbeat -lt 5) { throw "慢网络扫描期间 UI 心跳不足：$($Script:SelfTestUiHeartbeat)。" }
    }
    finally {
        if ($null -ne $heartbeatTimer) { try { $heartbeatTimer.Stop(); $heartbeatTimer.Dispose() } catch {} }
        if ($null -ne $Script:AsyncScan) {
            try { $Script:AsyncScan.PowerShell.Stop() } catch {}
            try { $Script:AsyncScan.PowerShell.Dispose() } catch {}
            $Script:AsyncScan = $null
        }
        $Script:ScannerPath = $originalScannerPath
        Remove-Item -LiteralPath $slowScannerScript -Force -ErrorAction SilentlyContinue
    }
    $upstream = $base.PSObject.Copy()
    $upstream.proxyFailureCandidate = $true
    $upstream.proxyHealthy = $false
    Reset-UpstreamHealthState
    $Script:UpstreamFailureSince = (Get-Date).AddSeconds(-61)
    Update-UpstreamHealth -State $upstream
    if (-not $Script:UpstreamEventStarted -or $Script:UpstreamNotified) { throw '线路失败60秒分级逻辑错误。' }
    $Script:UpstreamFailureSince = (Get-Date).AddSeconds(-181)
    Update-UpstreamHealth -State $upstream
    if (-not $Script:UpstreamNotified -or -not $Script:UpstreamActionAvailable) { throw '线路失败3分钟提醒逻辑错误。' }
    Update-UpstreamHealth -State $base
    Update-UpstreamHealth -State $base
    if ($null -ne $Script:UpstreamFailureSince) { throw '线路恢复双采样逻辑错误。' }
        Write-Host '监控自检通过：客户端状态文案、冲突解决入口、文件锁重试、日志轮转、点击异常隔离、状态指纹、冲突分类、防抖、误关系统代理恢复边界、慢网络 UI 心跳、非阻塞自动急救和线路分级提醒逻辑正常。' -ForegroundColor Green
    }
    finally { $Script:TestMode = $false }
}

function Get-LongmaoConnectionMonitorProcesses {
    if (-not (Test-Path -LiteralPath $Script:LongmaoConnectionMonitorPath)) { return @() }
    $escapedPath = [regex]::Escape($Script:LongmaoConnectionMonitorPath)
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -match $escapedPath })
}

function Test-LongmaoCoreRunning {
    return @(
        Get-Process -Name 'lmclientCore' -ErrorAction SilentlyContinue
    ).Count -gt 0
}

function Start-LongmaoConnectionMonitorIfNeeded {
    # 只有检测到龙猫云核心时才启动，避免未使用龙猫云的用户产生无意义的断连记录。
    if (-not (Test-LongmaoCoreRunning)) { return }
    if (@(Get-LongmaoConnectionMonitorProcesses).Count -gt 0) { return }
    if (Test-Path -LiteralPath $Script:LongmaoConnectionStopFlagPath) {
        Remove-Item -LiteralPath $Script:LongmaoConnectionStopFlagPath -Force -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($Script:LongmaoConnectionMonitorPath)`"" -WindowStyle Hidden
    Write-MonitorLog -Level 'INFO' -Message '检测到龙猫云核心，已自动启动断连监控。'
}

function Stop-LongmaoConnectionMonitor {
    $running = @(Get-LongmaoConnectionMonitorProcesses)
    if ($running.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $Script:LongmaoConnectionDataDirectory)) {
        New-Item -ItemType Directory -Path $Script:LongmaoConnectionDataDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $Script:LongmaoConnectionStopFlagPath -Value (Get-Date -Format 'o') -Encoding UTF8
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $running = @(Get-LongmaoConnectionMonitorProcesses)
    } while ($running.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($running.Count -gt 0) {
        foreach ($process in $running) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-TrayMonitor {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'KerryNetworkRescueReadOnlyMonitor', [ref]$createdNew)
    if (-not $createdNew) {
        Write-MonitorLog -Level 'INFO' -Message '后台监控已经运行，本次启动退出。'
        return
    }

    try {
        if (Test-Path -LiteralPath $Script:StopFlagPath) { Remove-Item -LiteralPath $Script:StopFlagPath -Force }
        Start-LongmaoConnectionMonitorIfNeeded
        $context = New-Object System.Windows.Forms.ApplicationContext
        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $Script:NotifyIcon = $notifyIcon
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
        $notifyIcon.Text = '断网急救：正在读取网络状态'
        $notifyIcon.Visible = $true

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.ShowItemToolTips = $true
        $statusItem = $menu.Items.Add('网络状态：正在检查')
        $emergencyItem = $menu.Items.Add('一键退出全部代理并恢复普通网络')
        $autoRecoveryItem = $menu.Items.Add($(if($Script:AutoRecoveryEnabled){'系统代理异常时自动急救：已开启'}else{'系统代理异常时自动急救：已关闭'}))
        $exitItem = $menu.Items.Add('退出断网急救')
        $statusItem.ToolTipText = '查看当前由哪个代理软件接管网络，以及是否发现冲突。'
        $emergencyItem.ToolTipText = '退出全部已识别的代理界面、核心和服务，清理已知残留并确认普通网络恢复。'
        $autoRecoveryItem.ToolTipText = '无人监听时关闭失效代理；其他客户端退出误关主代理时，复核通过后自动恢复。'
        $emergencyItem.ForeColor = [System.Drawing.Color]::DarkRed
        $notifyIcon.ContextMenuStrip = $menu
        $notifyIcon.add_BalloonTipClicked({
            Invoke-TrayActionSafely -ActionName '处理代理线路异常' -Action {
                if (-not $Script:UpstreamActionAvailable) { return }
                if (Confirm-RepairAction '代理线路持续异常' '本地代理端口仍正常，但多个线路探测持续失败。建议先在客户端更新节点。是否现在关闭系统代理并恢复普通网络？') {
                    $Script:UpstreamActionAvailable = $false
                    [void](Start-RepairAction -RepairMode 'RestoreDirect' -TrackRepair $true)
                }
            }
        })

        $menu.add_Opening({
            try {
                if ($null -eq $Script:StableState) {
                    $statusItem.Text = '网络状态：正在检查'
                }
                elseif ($Script:UpstreamNotified) {
                    $statusItem.Text = '网络状态：代理线路持续异常'
                }
                elseif ($null -ne $Script:UpstreamFailureSince -and ((Get-Date) - $Script:UpstreamFailureSince).TotalSeconds -ge 30) {
                    $statusItem.Text = '网络状态：代理线路暂时异常'
                }
                elseif ([int]$Script:StableState.conflictCount -gt 0) {
                    $statusItem.Text = "网络状态：发现 $($Script:StableState.conflictCount) 个问题"
                }
                else {
                    $statusItem.Text = '网络状态：未发现冲突'
                }

                $emergencyItem.Enabled = ($null -eq $Script:PendingRepair)
                $autoRecoveryItem.Text = if ($Script:AutoRecoveryEnabled) { '系统代理异常时自动急救：已开启' } else { '系统代理异常时自动急救：已关闭' }
            }
            catch {
                $statusItem.Text = '网络状态：暂时无法读取'
                $emergencyItem.Enabled = $false
                try { Write-MonitorLog -Level 'ERROR' -Message "刷新托盘菜单失败：$($_.Exception.Message)" } catch {}
            }
        })

        $statusItem.add_Click({
            Invoke-TrayActionSafely -ActionName '查看网络状态' -Action {
                if ($null -eq $Script:StableState) { return }
                if ((Show-NetworkStatusDialog -State $Script:StableState) -eq 'Repair') {
                    Invoke-EmergencyCleanupFromTray
                }
            }
        })
        $autoRecoveryItem.add_Click({
            Invoke-TrayActionSafely -ActionName '切换自动急救' -Action {
                if ($Script:AutoRecoveryEnabled -and -not (Confirm-RepairAction '关闭系统代理自动急救' '关闭后仍会检查网络状态，但不会自动关闭无人监听的失效代理，也不会自动恢复被其他客户端误关的主代理。是否关闭？')) { return }
                $Script:AutoRecoveryEnabled = -not $Script:AutoRecoveryEnabled
                $Script:StaleProxyServer = ''
                $Script:StaleProxyCount = 0
                $Script:PendingSystemProxyRestore = $null
                $autoRecoveryItem.Text = if ($Script:AutoRecoveryEnabled) { '系统代理异常时自动急救：已开启' } else { '系统代理异常时自动急救：已关闭' }
                Write-MonitorLog -Level 'INFO' -Message $(if($Script:AutoRecoveryEnabled){'自动急救已开启。'}else{'自动急救已关闭，后台继续只读监控。'})
            }
        })
        $emergencyItem.add_Click({
            Invoke-TrayActionSafely -ActionName '一键恢复普通网络' -Action {
                Invoke-EmergencyCleanupFromTray
            }
        })
        $exitItem.add_Click({
            Invoke-TrayActionSafely -ActionName '退出断网急救' -Action {
                if (Confirm-RepairAction '退出断网急救' '退出后将停止本次后台检查、断网自动恢复和龙猫云断连监控；下次登录 Windows 时仍会按开机启动设置运行。是否退出？') {
                    $notifyIcon.Visible = $false
                    $context.ExitThread()
                }
            }
        })

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 500
        $timer.add_Tick({
            if (Test-Path -LiteralPath $Script:StopFlagPath) {
                Write-MonitorLog -Level 'INFO' -Message '收到停止请求，后台监控准备退出。'
                $timer.Stop()
                $notifyIcon.Visible = $false
                $context.ExitThread()
                return
            }
            try {
                [void](Complete-AsyncMonitorScan)
                if ($null -eq $Script:AsyncScan -and (Get-Date) -ge $Script:NextFullScanAt) {
                    Start-LongmaoConnectionMonitorIfNeeded
                    Start-AsyncMonitorScan
                    $Script:NextFullScanAt = (Get-Date).AddSeconds($IntervalSeconds)
                }
            }
            catch { Write-MonitorLog -Level 'ERROR' -Message "后台扫描失败：$($_.Exception.Message)" }
        })

        $autoRecoveryTimer = New-Object System.Windows.Forms.Timer
        $autoRecoveryTimer.Interval = $AutoRecoveryIntervalSeconds * 1000
        $autoRecoveryTimer.add_Tick({
            try {
                Complete-PendingSystemProxyRestore | Out-Null
                Complete-PendingAutoRecovery | Out-Null
                if ($Script:AutoRecoveryEnabled) { Invoke-LightweightAutoRecoveryCheck | Out-Null }
            }
            catch { Write-MonitorLog -Level 'ERROR' -Message "自动急救检查失败：$($_.Exception.Message)" }
        })

        Write-MonitorLog -Level 'INFO' -Message "后台监控 v$Script:Version 已启动，完整扫描间隔 $IntervalSeconds 秒，状态确认 $ConfirmationSamples 次，自动急救=$(if($Script:AutoRecoveryEnabled){'开启'}else{'关闭'})，轻量检查间隔 $AutoRecoveryIntervalSeconds 秒，失效代理确认 $AutoRecoverySamples 次。"
        Start-AsyncMonitorScan
        $Script:NextFullScanAt = (Get-Date).AddSeconds($IntervalSeconds)
        $timer.Start()
        $autoRecoveryTimer.Start()
        [System.Windows.Forms.Application]::Run($context)
        $timer.Stop()
        $autoRecoveryTimer.Stop()
        if ($null -ne $Script:AsyncScan) {
            try { $Script:AsyncScan.PowerShell.Stop() } catch {}
            try { $Script:AsyncScan.PowerShell.Dispose() } catch {}
            $Script:AsyncScan = $null
        }
        if ($null -ne $Script:AsyncDirectProbe) {
            try { $Script:AsyncDirectProbe.PowerShell.Stop() } catch {}
            try { $Script:AsyncDirectProbe.PowerShell.Dispose() } catch {}
            $Script:AsyncDirectProbe = $null
        }
        if ($null -ne $Script:AsyncSystemProxyRestoreProbe) {
            try { $Script:AsyncSystemProxyRestoreProbe.PowerShell.Stop() } catch {}
            try { $Script:AsyncSystemProxyRestoreProbe.PowerShell.Dispose() } catch {}
            $Script:AsyncSystemProxyRestoreProbe = $null
        }
        $notifyIcon.Dispose()
    }
    finally {
        Stop-LongmaoConnectionMonitor
        $Script:NotifyIcon = $null
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
        Write-MonitorLog -Level 'INFO' -Message '后台监控已退出。'
    }
}

if ($SelfTest) {
    Invoke-MonitorSelfTest
    return
}

if ($Once) {
    $sample = Invoke-MonitorScan
    Write-Host '只读监控单次采样完成。' -ForegroundColor Green
    Write-Host "有效 Owner：$($sample.State.effectiveOwner)"
    Write-Host "系统代理 Owner：$(if($sample.State.systemProxyOwner){$sample.State.systemProxyOwner}else{'无'})"
    Write-Host "冲突数量：$($sample.State.conflictCount)"
    return
}

Start-TrayMonitor
