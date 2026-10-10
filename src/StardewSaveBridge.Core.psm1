Set-StrictMode -Version Latest

$script:BridgeUiLabels = [ordered]@{
    InspectSaves         = 'Inspect saves'
    UsePCSave            = 'Use PC save'
    UsePhoneSave         = 'Use Phone save'
    RestoreBackup        = 'Restore backup'
    RunSyncDaemon        = 'Run sync daemon'
    Cancel               = 'Cancel'
    ConfirmOverwrite     = 'Confirm overwrite'
    BackUpCurrentVersion = 'Back up current version'
    SavesAreIdentical    = 'Saves are identical'
    SavesDiffer          = 'Saves differ'
    CompatibilityFailed  = 'Compatibility check failed'
    VerificationOk       = 'Verification succeeded'
    VerificationFailed   = 'Verification failed'
    Exit                 = 'Exit'
}

function Get-BridgeUiLabels {
    return [ordered]@{} + $script:BridgeUiLabels
}

function Get-DefaultBridgeConfig {
    return [ordered]@{
        androidSaveRoot    = '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves'
        adbPath            = 'adb'
        backupRoot         = 'backups'
        retentionCount     = 5
        stagingDirectory   = 'staging'
        preferredSaveSlot  = ''
        preferredDeviceId  = ''
        wirelessDeviceHost = ''
        wirelessDevicePort = 0
        daemonIntervalMinutes = 30
        uiMode             = 'Text'
        allowUnsafeOverride = $false
        pcGameExePath      = ''
        phonePackageName   = 'com.chucklefish.stardewvalley'
        logRoot            = 'logs'
    }
}

function Merge-BridgeConfig {
    param(
        [Parameter(Mandatory)]
        [hashtable]$BaseConfig,

        [Parameter(Mandatory)]
        [hashtable]$OverrideConfig
    )

    $merged = [ordered]@{}

    foreach ($key in $BaseConfig.Keys) {
        $merged[$key] = $BaseConfig[$key]
    }

    foreach ($key in $OverrideConfig.Keys) {
        $merged[$key] = $OverrideConfig[$key]
    }

    return $merged
}

function ConvertTo-Hashtable {
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [hashtable]) {
        return $InputObject
    }

    $result = @{}

    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}

function Resolve-BridgeAbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $RepositoryRoot -ChildPath $Path))
}

function Ensure-BridgeDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return $Path
}

function Initialize-BridgeConfig {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $resolvedConfigPath = Resolve-BridgeAbsolutePath -RepositoryRoot $RepositoryRoot -Path $ConfigPath
    $configDirectory = Split-Path -Path $resolvedConfigPath -Parent

    Ensure-BridgeDirectory -Path $configDirectory | Out-Null

    $defaultsPath = Join-Path -Path $RepositoryRoot -ChildPath 'config/default.json'
    $defaults = Get-DefaultBridgeConfig

    if (Test-Path -LiteralPath $defaultsPath) {
        $defaultFileData = Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json
        $defaults = Merge-BridgeConfig -BaseConfig $defaults -OverrideConfig (ConvertTo-Hashtable -InputObject $defaultFileData)
    }

    if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
        $defaults | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resolvedConfigPath -Encoding UTF8
    }

    $userConfigData = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
    $config = Merge-BridgeConfig -BaseConfig $defaults -OverrideConfig (ConvertTo-Hashtable -InputObject $userConfigData)

    $config['_configPath'] = $resolvedConfigPath
    $config['_repositoryRoot'] = $RepositoryRoot
    $config['backupRoot'] = Resolve-BridgeAbsolutePath -RepositoryRoot $RepositoryRoot -Path $config.backupRoot
    $config['stagingDirectory'] = Resolve-BridgeAbsolutePath -RepositoryRoot $RepositoryRoot -Path $config.stagingDirectory
    $config['logRoot'] = Resolve-BridgeAbsolutePath -RepositoryRoot $RepositoryRoot -Path $config.logRoot

    return $config
}

function Save-BridgePreferences {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [hashtable]$Preferences
    )

    foreach ($key in $Preferences.Keys) {
        $Config[$key] = $Preferences[$key]
    }

    $persisted = [ordered]@{}

    foreach ($key in (Get-DefaultBridgeConfig).Keys) {
        $persisted[$key] = $Config[$key]
    }

    $persisted | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-BridgeTimestamp {
    return (Get-Date).ToString('yyyyMMdd-HHmmssfff')
}

function New-BridgeRunRecord {
    param(
        [string]$Action,
        [switch]$DryRun,
        [switch]$Force,
        [string]$ConfigPath
    )

    return [ordered]@{
        startedAt         = (Get-Date).ToString('o')
        modeSelected      = if ($Action) { $Action } else { 'Interactive' }
        dryRun            = [bool]$DryRun
        force             = [bool]$Force
        configPath        = $ConfigPath
        selectedSaveSlot  = ''
        detectedPaths     = @{}
        connectedDeviceId = ''
        deviceSelection   = @{}
        compatibility     = @{}
        backupResult      = @{}
        comparisonSummary = @{}
        overwriteTarget   = ''
        preservedSettings = @{}
        verificationResult = @{}
        cycleDeviceEndpoint = ''
        syncResults       = @()
        notes             = @()
        finalOutcome      = 'Unknown'
        errors            = @()
    }
}

function Write-BridgeRunLog {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$RunRecord,

        [switch]$PassThru
    )

    $logRoot = Ensure-BridgeDirectory -Path $Config.logRoot
    $stamp = Get-BridgeTimestamp
    $slotLabel = if ([string]::IsNullOrWhiteSpace($RunRecord.selectedSaveSlot)) { 'no-slot' } else { $RunRecord.selectedSaveSlot }
    $baseName = '{0}-{1}' -f $stamp, ($slotLabel -replace '[^A-Za-z0-9._-]', '_')
    $jsonPath = Join-Path -Path $logRoot -ChildPath ($baseName + '.json')
    $textPath = Join-Path -Path $logRoot -ChildPath ($baseName + '.log')

    $RunRecord['finishedAt'] = (Get-Date).ToString('o')
    $RunRecord | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $deviceSelectionMessage = ''
    if ($RunRecord.Contains('deviceSelection') -and $RunRecord.deviceSelection) {
        if ($RunRecord.deviceSelection -is [System.Collections.IDictionary]) {
            if ($RunRecord.deviceSelection.Contains('message') -and -not [string]::IsNullOrWhiteSpace([string]$RunRecord.deviceSelection['message'])) {
                $deviceSelectionMessage = [string]$RunRecord.deviceSelection['message']
            }
        }
        elseif ($RunRecord.deviceSelection.PSObject.Properties.Name -contains 'message' -and -not [string]::IsNullOrWhiteSpace([string]$RunRecord.deviceSelection.message)) {
            $deviceSelectionMessage = [string]$RunRecord.deviceSelection.message
        }
    }

    $lines = @(
        'Timestamp: {0}' -f $RunRecord.startedAt
        'Mode: {0}' -f $RunRecord.modeSelected
        'Save Slot: {0}' -f $RunRecord.selectedSaveSlot
        'Device: {0}' -f $RunRecord.connectedDeviceId
        'Device Selection: {0}' -f $deviceSelectionMessage
        'Endpoint: {0}' -f $RunRecord.cycleDeviceEndpoint
        'Overwrite Target: {0}' -f $RunRecord.overwriteTarget
        'Outcome: {0}' -f $RunRecord.finalOutcome
        'Detected Paths:'
    )

    foreach ($key in $RunRecord.detectedPaths.Keys) {
        $lines += '  {0}: {1}' -f $key, $RunRecord.detectedPaths[$key]
    }

    $lines += @(
        'Compatibility: {0}' -f (($RunRecord.compatibility | ConvertTo-Json -Compress -Depth 10))
        'Comparison Summary: {0}' -f (($RunRecord.comparisonSummary | ConvertTo-Json -Compress -Depth 10))
        'Backup Result: {0}' -f (($RunRecord.backupResult | ConvertTo-Json -Compress -Depth 10))
        'Preserved Settings: {0}' -f (($RunRecord.preservedSettings | ConvertTo-Json -Compress -Depth 10))
        'Verification Result: {0}' -f (($RunRecord.verificationResult | ConvertTo-Json -Compress -Depth 10))
    )

    if ($RunRecord.syncResults.Count -gt 0) {
        $lines += 'Per-slot Results:'
        foreach ($syncResult in $RunRecord.syncResults) {
            $slotName = if ([string]::IsNullOrWhiteSpace($syncResult.SlotName)) { 'unknown-slot' } else { $syncResult.SlotName }
            $status = if ([string]::IsNullOrWhiteSpace($syncResult.Status)) { 'Unknown' } else { $syncResult.Status }
            $direction = if ($syncResult.SourceSide -and $syncResult.TargetSide) { ' [{0}->{1}]' -f $syncResult.SourceSide, $syncResult.TargetSide } else { '' }
            $detail = if ($syncResult.Reason) { $syncResult.Reason } else { 'No additional detail was recorded.' }
            $lines += '  {0}: {1}{2} - {3}' -f $slotName, $status, $direction, $detail
        }

        $lines += 'Sync Results JSON: {0}' -f (($RunRecord.syncResults | ConvertTo-Json -Compress -Depth 10))
    }
    else {
        $lines += 'Sync Results JSON: {0}' -f (($RunRecord.syncResults | ConvertTo-Json -Compress -Depth 10))
    }

    if ($RunRecord.notes.Count -gt 0) {
        $lines += 'Notes:'
        foreach ($note in $RunRecord.notes) {
            $lines += '  {0}' -f $note
        }
    }

    if ($RunRecord.errors.Count -gt 0) {
        $lines += 'Errors:'
        foreach ($message in $RunRecord.errors) {
            $lines += '  {0}' -f $message
        }
    }

    $lines | Set-Content -LiteralPath $textPath -Encoding UTF8

    if ($PassThru) {
        return [pscustomobject]@{
            JsonPath = $jsonPath
            TextPath = $textPath
        }
    }
}

function Copy-BridgeDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$TargetPath,

        [switch]$CleanTarget
    )

    if ($CleanTarget -and (Test-Path -LiteralPath $TargetPath)) {
        Remove-Item -LiteralPath $TargetPath -Recurse -Force
    }

    Ensure-BridgeDirectory -Path (Split-Path -Path $TargetPath -Parent) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Recurse -Force
}

function Get-BridgeRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$ChildPath
    )

    $rootUri = New-Object System.Uri((Resolve-Path -LiteralPath $RootPath).Path.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar)
    $childUri = New-Object System.Uri((Resolve-Path -LiteralPath $ChildPath).Path)
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($childUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

Export-ModuleMember -Function @(
    'Get-BridgeUiLabels',
    'Get-DefaultBridgeConfig',
    'Merge-BridgeConfig',
    'ConvertTo-Hashtable',
    'Resolve-BridgeAbsolutePath',
    'Ensure-BridgeDirectory',
    'Initialize-BridgeConfig',
    'Save-BridgePreferences',
    'Get-BridgeTimestamp',
    'New-BridgeRunRecord',
    'Write-BridgeRunLog',
    'Copy-BridgeDirectory',
    'Get-BridgeRelativePath'
)
