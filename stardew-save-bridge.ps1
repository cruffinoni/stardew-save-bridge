[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'UsePC', 'UsePhone', 'RestoreBackup')]
    [string]$Action,

    [string]$SaveSlot,

    [string]$DeviceId,

    [string]$BackupId,

    [string]$ConfigPath,

    [string]$BackupRoot,

    [switch]$DryRun,

    [switch]$Force,

    [switch]$NonInteractive,

    [ValidateSet('Text', 'Grid')]
    [string]$UiMode,

    [ValidateSet('PC', 'Phone')]
    [string]$RestoreTarget
)

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
elseif ($PSCommandPath) {
    Split-Path -Path $PSCommandPath -Parent
}
else {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $scriptRoot -ChildPath 'config/user.json'
}

$modulePaths = @(
    'src/StardewSaveBridge.Core.psm1',
    'src/StardewSaveBridge.Save.psm1',
    'src/StardewSaveBridge.Adb.psm1',
    'src/StardewSaveBridge.Backup.psm1',
    'src/StardewSaveBridge.Workflow.psm1'
)

foreach ($modulePath in $modulePaths) {
    Import-Module -Name (Join-Path -Path $scriptRoot -ChildPath $modulePath) -Force -DisableNameChecking
}

$config = Initialize-BridgeConfig -ConfigPath $ConfigPath -RepositoryRoot $scriptRoot

if ($BackupRoot) {
    $config.backupRoot = Resolve-BridgeAbsolutePath -RepositoryRoot $scriptRoot -Path $BackupRoot
}

if ($UiMode) {
    $config.uiMode = $UiMode
}

$runRecord = New-BridgeRunRecord -Action $Action -DryRun:$DryRun -Force:$Force -ConfigPath $config._configPath

try {
    $invokeParams = @{
        Config = $config
        RepositoryRoot = $scriptRoot
        DryRun = [bool]$DryRun
        Force = [bool]$Force
        NonInteractive = [bool]$NonInteractive
        RunRecord = $runRecord
    }

    if (-not [string]::IsNullOrWhiteSpace($Action)) {
        $invokeParams.Action = $Action
    }

    if (-not [string]::IsNullOrWhiteSpace($SaveSlot)) {
        $invokeParams.SaveSlot = $SaveSlot
    }

    if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
        $invokeParams.DeviceId = $DeviceId
    }

    if (-not [string]::IsNullOrWhiteSpace($BackupId)) {
        $invokeParams.BackupId = $BackupId
    }

    if (-not [string]::IsNullOrWhiteSpace($RestoreTarget)) {
        $invokeParams.RestoreTarget = $RestoreTarget
    }

    $result = Invoke-BridgeAction @invokeParams

    if ($result.Preferences) {
        Save-BridgePreferences -Config $config -ConfigPath $config._configPath -Preferences $result.Preferences
    }

    $runRecord.finalOutcome = $result.FinalOutcome
    $runRecord.compatibility = $result.Compatibility
    $runRecord.comparisonSummary = $result.ComparisonSummary
    $runRecord.overwriteTarget = $result.OverwriteTarget
    $runRecord.verificationResult = $result.VerificationResult
    $runRecord.errors = $result.Errors

    Write-BridgeRunLog -Config $config -RepositoryRoot $scriptRoot -RunRecord $runRecord

    if ($result.OutputLines) {
        $result.OutputLines | ForEach-Object { Write-Host $_ }
    }

    if ($result.ExitCode -ne 0) {
        exit $result.ExitCode
    }
}
catch {
    $runRecord.finalOutcome = 'Failed'
    $runRecord.errors = @($_.Exception.Message)
    Write-BridgeRunLog -Config $config -RepositoryRoot $scriptRoot -RunRecord $runRecord
    throw
}
