Set-StrictMode -Version Latest

function Select-BridgeItem {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [scriptblock]$LabelScript,

        [Parameter(Mandatory)]
        [string]$UiMode,

        [switch]$NonInteractive
    )

    if ($Items.Count -eq 0) {
        throw "No options are available for $Title."
    }

    if ($Items.Count -eq 1) {
        return $Items[0]
    }

    if ($NonInteractive) {
        throw "$Title requires an explicit selection in non-interactive mode."
    }

    if ($UiMode -eq 'Grid' -and (Get-Command -Name Out-GridView -ErrorAction SilentlyContinue)) {
        $gridItems = $Items | ForEach-Object {
            [pscustomobject]@{
                Label = (& $LabelScript $_)
                Value = $_
            }
        }

        $selected = $gridItems | Out-GridView -PassThru -Title $Title
        if (-not $selected) {
            throw "$Title was canceled."
        }

        return $selected.Value
    }

    Write-Host $Title
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host ('[{0}] {1}' -f ($index + 1), (& $LabelScript $Items[$index]))
    }

    $choice = Read-Host 'Enter a number'
    $choiceIndex = 0
    if (-not [int]::TryParse($choice, [ref]$choiceIndex) -or $choiceIndex -lt 1 -or $choiceIndex -gt $Items.Count) {
        throw "Invalid selection for $Title."
    }

    return $Items[$choiceIndex - 1]
}

function Confirm-BridgeAction {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [switch]$Force,

        [switch]$NonInteractive
    )

    if ($Force) {
        return $true
    }

    if ($NonInteractive) {
        throw "$Message Confirmation is required unless -Force is provided."
    }

    $response = Read-Host ($Message + ' [y/N]')
    return $response -match '^(y|yes)$'
}

function Get-MainMenuAction {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $labels = Get-BridgeUiLabels
    $items = @(
        [pscustomobject]@{ Value = 'Inspect'; Label = $labels.InspectSaves },
        [pscustomobject]@{ Value = 'UsePC'; Label = $labels.UsePCSave },
        [pscustomobject]@{ Value = 'UsePhone'; Label = $labels.UsePhoneSave },
        [pscustomobject]@{ Value = 'RestoreBackup'; Label = $labels.RestoreBackup },
        [pscustomobject]@{ Value = 'Exit'; Label = $labels.Exit }
    )

    $selected = Select-BridgeItem -Items $items -Title 'Choose an action' -LabelScript { param($item) $item.Label } -UiMode $Config.uiMode
    return $selected.Value
}

function Resolve-SelectedDevice {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$RequestedDeviceId,

        [switch]$NonInteractive
    )

    if (-not (Test-AdbAvailable -Config $Config)) {
        throw 'adb is not available. Install adb or set adbPath in the config file.'
    }

    $devices = @(Get-AdbDeviceList -Config $Config)
    if ($devices.Count -eq 0) {
        throw 'No Android device is connected.'
    }

    $unauthorized = @($devices | Where-Object { $_.State -eq 'unauthorized' })
    if ($unauthorized.Count -gt 0) {
        throw 'An Android device is connected but unauthorized. Unlock the phone and allow USB debugging.'
    }

    $onlineDevices = @($devices | Where-Object { $_.State -eq 'device' })
    if ($onlineDevices.Count -eq 0) {
        throw 'No authorized Android device is available.'
    }

    if ($RequestedDeviceId) {
        $requested = $onlineDevices | Where-Object { $_.Id -eq $RequestedDeviceId } | Select-Object -First 1
        if (-not $requested) {
            throw "Requested device '$RequestedDeviceId' is not connected."
        }

        return $requested
    }

    if ($Config.preferredDeviceId) {
        $preferred = $onlineDevices | Where-Object { $_.Id -eq $Config.preferredDeviceId } | Select-Object -First 1
        if ($preferred) {
            return $preferred
        }
    }

    return Select-BridgeItem -Items $onlineDevices -Title 'Choose a phone device' -LabelScript { param($item) "$($item.Id) [$($item.State)]" } -UiMode $Config.uiMode -NonInteractive:$NonInteractive
}

function Resolve-SelectedSaveSlot {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$RequestedSaveSlot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$PcSlots,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$PhoneSlots,

        [switch]$NonInteractive
    )

    $allSlots = @(
        @($PcSlots | ForEach-Object { $_.Name }) +
        @($PhoneSlots | ForEach-Object { $_.Name }) |
        Sort-Object -Unique |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($allSlots.Count -eq 0) {
        throw 'No save slots were found on either side.'
    }

    if ($RequestedSaveSlot) {
        if ($allSlots -notcontains $RequestedSaveSlot) {
            throw "Save slot '$RequestedSaveSlot' was not found on either side."
        }

        return $RequestedSaveSlot
    }

    if ($allSlots.Count -eq 1) {
        return $allSlots[0]
    }

    if ($NonInteractive) {
        throw 'Multiple save slots found. Re-run with -SaveSlot or SLOT=<name>.'
    }

    $preferredSlot = if ($Config.preferredSaveSlot -and $allSlots -contains $Config.preferredSaveSlot) { $Config.preferredSaveSlot } else { $null }
    $orderedSlots = @()

    if ($preferredSlot) {
        $orderedSlots += $preferredSlot
    }

    $orderedSlots += @($allSlots | Where-Object { $_ -ne $preferredSlot })

    $items = $orderedSlots | ForEach-Object {
        [pscustomobject]@{
            Name = $_
            IsPreferred = ($preferredSlot -and $_ -eq $preferredSlot)
        }
    }

    $selected = Select-BridgeItem -Items $items -Title 'Choose a save slot' -LabelScript {
        param($item)
        if ($item.IsPreferred) {
            return "$($item.Name) (last used)"
        }

        return $item.Name
    } -UiMode $Config.uiMode -NonInteractive:$NonInteractive
    return $selected.Name
}

function New-StagingSlotPath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$Purpose,

        [Parameter(Mandatory)]
        [string]$SlotName
    )

    $path = Join-Path -Path $Config.stagingDirectory -ChildPath (Join-Path -Path $Purpose -ChildPath (Join-Path -Path (Get-BridgeTimestamp) -ChildPath $SlotName))
    Ensure-BridgeDirectory -Path (Split-Path -Path $path -Parent) | Out-Null
    return $path
}

function Get-SlotPathByName {
    param(
        [Parameter(Mandatory)]
        [object[]]$Slots,

        [Parameter(Mandatory)]
        [string]$SlotName
    )

    $match = $Slots | Where-Object { $_.Name -eq $SlotName } | Select-Object -First 1
    if ($match) {
        return $match.Path
    }

    return $null
}

function Get-BackupSlotNames {
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object -Property Name | Select-Object -ExpandProperty Name
}

function Get-CompatibilitySummary {
    param(
        [AllowNull()]
        $PcSaveVersion,

        [AllowNull()]
        $PhoneSaveVersion,

        [AllowNull()]
        $PcGameVersion,

        [AllowNull()]
        $PhoneGameVersion
    )

    return [ordered]@{
        pcToPhone = Test-VersionCompatibility -SaveVersion $PcSaveVersion -TargetGameVersion $PhoneGameVersion
        phoneToPc = Test-VersionCompatibility -SaveVersion $PhoneSaveVersion -TargetGameVersion $PcGameVersion
        pcSaveVersion = if ($PcSaveVersion) { $PcSaveVersion.ToString() } else { $null }
        phoneSaveVersion = if ($PhoneSaveVersion) { $PhoneSaveVersion.ToString() } else { $null }
        pcGameVersion = if ($PcGameVersion) { $PcGameVersion.ToString() } else { $null }
        phoneGameVersion = if ($PhoneGameVersion) { $PhoneGameVersion.ToString() } else { $null }
    }
}

function Get-InspectRecommendation {
    param(
        [Parameter(Mandatory)]
        [string]$OverallStatus,

        [Parameter(Mandatory)]
        [string]$NewerSideHint
    )

    if ($OverallStatus -eq 'Identical') {
        return 'Saves are identical. No handoff is needed.'
    }

    switch ($NewerSideHint) {
        'PC' { return 'PC save appears newer. Choose the version you want to keep.' }
        'Phone' { return 'Phone save appears newer. Choose the version you want to keep.' }
        default { return 'Review the comparison before choosing the version you want to keep.' }
    }
}

function Get-BackupSummaryLine {
    param(
        [Parameter(Mandatory)]
        $BackupResult,

        [Parameter(Mandatory)]
        [string]$NoBackupNeededMessage
    )

    if ($BackupResult.Created) {
        return 'Backup created: {0}' -f $BackupResult.BackupPath
    }

    if ($BackupResult.DryRun -and $BackupResult.BackupPath) {
        return 'Dry-run: backup would be created at {0}' -f $BackupResult.BackupPath
    }

    return $NoBackupNeededMessage
}

function Get-TargetActionSummaryLine {
    param(
        [Parameter(Mandatory)]
        [string]$Side,

        [Parameter(Mandatory)]
        [bool]$TargetExists,

        [switch]$DryRun
    )

    if ($TargetExists) {
        if ($DryRun) {
            return 'The current {0} save would be overwritten.' -f $Side
        }

        return 'The current {0} save was overwritten.' -f $Side
    }

    if ($DryRun) {
        return 'This action would create the save on the {0}.' -f $Side.ToLowerInvariant()
    }

    return 'The save was created on the {0}.' -f $Side.ToLowerInvariant()
}

function Get-VerificationSummaryLine {
    param(
        [Parameter(Mandatory)]
        $VerificationResult
    )

    switch ($VerificationResult.Status) {
        'DryRun' { return 'Verification skipped in dry-run mode.' }
        'Succeeded' { return 'Verification succeeded after comparing copied files.' }
        'Failed' { return 'Verification failed after comparing copied files.' }
        default {
            if ($VerificationResult.Reason) {
                return $VerificationResult.Reason
            }

            return 'Verification status: {0}' -f $VerificationResult.Status
        }
    }
}

function Get-PreservedSettingsSummaryLine {
    param(
        [Parameter(Mandatory)]
        $PreservationResult
    )

    if (-not $PreservationResult.Applied) {
        return $null
    }

    return 'Preserved existing {0} settings while replacing the save.' -f $PreservationResult.TargetSide
}

function New-EffectiveTransferPayload {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$Purpose,

        [Parameter(Mandatory)]
        [string]$SlotName,

        [Parameter(Mandatory)]
        [string]$IncomingSlotPath,

        [string]$CurrentTargetSlotPath,

        [Parameter(Mandatory)]
        [ValidateSet('PC', 'Phone')]
        [string]$TargetSide
    )

    if (-not $CurrentTargetSlotPath) {
        return [pscustomobject]@{
            Path = $IncomingSlotPath
            Applied = $false
            AppliedCount = 0
            CandidateCount = 0
            TargetSide = $TargetSide
            ReferencePath = $null
        }
    }

    $payloadPath = New-StagingSlotPath -Config $Config -Purpose $Purpose -SlotName $SlotName
    Copy-BridgeDirectory -SourcePath $IncomingSlotPath -TargetPath $payloadPath -CleanTarget
    $syncResult = Sync-SaveSettingsFromReference -ReferenceFolderPath $CurrentTargetSlotPath -TargetFolderPath $payloadPath

    return [pscustomobject]@{
        Path = $payloadPath
        Applied = $syncResult.Applied
        AppliedCount = $syncResult.AppliedCount
        CandidateCount = $syncResult.CandidateCount
        TargetSide = $TargetSide
        ReferencePath = $CurrentTargetSlotPath
    }
}

function Warn-IfStardewRunning {
    $candidates = @('Stardew Valley', 'StardewValley')
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $candidates -contains $_.ProcessName })
    if ($running.Count -gt 0) {
        Write-Warning 'Stardew Valley appears to be running on this PC. Close the game before copying saves.'
    }
}

function Invoke-InspectWorkflow {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$RequestedSaveSlot,

        [string]$RequestedDeviceId,

        [switch]$NonInteractive,

        [System.Collections.IDictionary]$RunRecord
    )

    $device = Resolve-SelectedDevice -Config $Config -RequestedDeviceId $RequestedDeviceId -NonInteractive:$NonInteractive
    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $device.Id

    $pcRoot = Get-WindowsSaveRoot
    $pcSlots = @(Get-LocalSaveSlots -RootPath $pcRoot -Side 'PC')
    $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
    $phoneSlotNames = @($phoneSlots | ForEach-Object { $_.Name })
    $slotName = Resolve-SelectedSaveSlot -Config $Config -RequestedSaveSlot $RequestedSaveSlot -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive:$NonInteractive

    $pcPath = Get-SlotPathByName -Slots $pcSlots -SlotName $slotName
    $stagedPhonePath = $null
    if ($phoneSlotNames -contains $slotName) {
        $stagedPhonePath = New-StagingSlotPath -Config $Config -Purpose 'inspect' -SlotName $slotName
        Copy-PhoneSaveToLocal -Config $Config -DeviceId $device.Id -SlotName $slotName -TargetPath $stagedPhonePath | Out-Null
    }

    $pcValidation = if ($pcPath) { Test-SaveFolder -FolderPath $pcPath } else { $null }
    $phoneValidation = if ($stagedPhonePath) { Test-SaveFolder -FolderPath $stagedPhonePath } else { $null }
    $comparison = Compare-SaveFolders -PCPath $pcPath -PhonePath $stagedPhonePath
    $pcGameVersion = Get-PCGameVersion -Config $Config
    $phoneGameVersion = Get-PhoneGameVersion -Config $Config -DeviceId $device.Id
    $compatibility = Get-CompatibilitySummary `
        -PcSaveVersion $(if ($pcValidation) { $pcValidation.SaveVersion.Parsed } else { $null }) `
        -PhoneSaveVersion $(if ($phoneValidation) { $phoneValidation.SaveVersion.Parsed } else { $null }) `
        -PcGameVersion $pcGameVersion.Parsed `
        -PhoneGameVersion $phoneGameVersion.Parsed

    $recommendation = Get-InspectRecommendation -OverallStatus $comparison.OverallStatus -NewerSideHint $comparison.NewerSideHint.Hint

    $statusLabel = if ($comparison.OverallStatus -eq 'Identical') { (Get-BridgeUiLabels).SavesAreIdentical } else { (Get-BridgeUiLabels).SavesDiffer }

    $RunRecord.selectedSaveSlot = $slotName
    $RunRecord.connectedDeviceId = $device.Id
    $RunRecord.detectedPaths = [ordered]@{
        pcRoot = $pcRoot
        pcSlot = $pcPath
        androidRoot = $androidSaveRoot
        phoneSlot = if ($slotName) { $androidSaveRoot.TrimEnd('/') + '/' + $slotName } else { $null }
        stagingPhoneSlot = $stagedPhonePath
    }
    $RunRecord.compatibility = $compatibility
    $RunRecord.comparisonSummary = $comparison.Summary

    return [pscustomobject]@{
        ExitCode = 0
        FinalOutcome = 'Completed'
        Compatibility = $compatibility
        ComparisonSummary = $comparison.Summary
        OverwriteTarget = ''
        VerificationResult = @{}
        Errors = @()
        Preferences = @{ preferredSaveSlot = $slotName; preferredDeviceId = $device.Id }
        OutputLines = @(
            "Selected save slot: $slotName"
            "PC path: $pcPath"
            "Phone path: $($androidSaveRoot.TrimEnd('/') + '/' + $slotName)"
            "File comparison: $statusLabel"
            "Only on PC: $($comparison.Summary.onlyOnPC)"
            "Only on Phone: $($comparison.Summary.onlyOnPhone)"
            "Content differs: $($comparison.Summary.contentDiffers)"
            "Latest timestamp hint: $($comparison.NewerSideHint.Hint)"
            "PC save version: $($compatibility.pcSaveVersion)"
            "Phone save version: $($compatibility.phoneSaveVersion)"
            "PC game version: $($compatibility.pcGameVersion)"
            "Phone game version: $($compatibility.phoneGameVersion)"
            "PC to Phone: $($compatibility.pcToPhone.Status) - $($compatibility.pcToPhone.Reason)"
            "Phone to PC: $($compatibility.phoneToPc.Status) - $($compatibility.phoneToPc.Reason)"
            $recommendation
        )
    }
}

function Invoke-UsePCWorkflow {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$RequestedSaveSlot,

        [string]$RequestedDeviceId,

        [switch]$DryRun,

        [switch]$Force,

        [switch]$NonInteractive,

        [System.Collections.IDictionary]$RunRecord
    )

    $device = Resolve-SelectedDevice -Config $Config -RequestedDeviceId $RequestedDeviceId -NonInteractive:$NonInteractive
    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $device.Id

    $pcRoot = Get-WindowsSaveRoot
    $pcSlots = @(Get-LocalSaveSlots -RootPath $pcRoot -Side 'PC')
    $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
    $phoneSlotNames = @($phoneSlots | ForEach-Object { $_.Name })
    $slotName = Resolve-SelectedSaveSlot -Config $Config -RequestedSaveSlot $RequestedSaveSlot -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive:$NonInteractive
    $pcPath = Get-SlotPathByName -Slots $pcSlots -SlotName $slotName
    if (-not $pcPath) {
        throw "Use PC save requires the save slot '$slotName' to exist on the PC."
    }

    $pcValidation = Test-SaveFolder -FolderPath $pcPath
    if (-not $pcValidation.IsValid -and -not ($Force -or $Config.allowUnsafeOverride)) {
        throw "The PC save '$slotName' is incomplete or unreadable."
    }

    $stagedPhonePath = $null
    $phoneExists = $phoneSlotNames -contains $slotName
    if ($phoneExists) {
        $stagedPhonePath = New-StagingSlotPath -Config $Config -Purpose 'phone-current' -SlotName $slotName
        Copy-PhoneSaveToLocal -Config $Config -DeviceId $device.Id -SlotName $slotName -TargetPath $stagedPhonePath | Out-Null
    }

    $phoneValidation = if ($stagedPhonePath) { Test-SaveFolder -FolderPath $stagedPhonePath } else { $null }
    $comparison = Compare-SaveFolders -PCPath $pcPath -PhonePath $stagedPhonePath
    $phoneGameVersion = Get-PhoneGameVersion -Config $Config -DeviceId $device.Id
    $compatibility = Test-VersionCompatibility -SaveVersion $pcValidation.SaveVersion.Parsed -TargetGameVersion $phoneGameVersion.Parsed

    if ($compatibility.Status -eq 'Blocked' -and -not $Force) {
        throw "Compatibility check failed. $($compatibility.Reason)"
    }

    if (-not (Confirm-BridgeAction -Message 'Use PC save and overwrite the phone version? A backup of the overwritten side will be created first.' -Force:$Force -NonInteractive:$NonInteractive)) {
        return [pscustomobject]@{
            ExitCode = 1
            FinalOutcome = 'Canceled'
            Compatibility = $compatibility
            ComparisonSummary = $comparison.Summary
            OverwriteTarget = 'Phone'
            VerificationResult = @{}
            Errors = @()
            Preferences = @{}
            OutputLines = @('Operation canceled.')
        }
    }

    $backupResult = if ($phoneExists) {
        $metadata = @{
            sourceSide = 'Phone'
            targetSide = 'Phone'
            saveSlot = $slotName
            operationType = 'UsePCSave'
            deviceId = $device.Id
        }
        New-BridgeBackup -SlotName $slotName -TargetSide 'Phone' -OperationType 'UsePCSave' -SourcePath $stagedPhonePath -BackupRoot $Config.backupRoot -Metadata $metadata -DryRun:$DryRun
    }
    else {
        [pscustomobject]@{
            Created = $false
            DryRun = [bool]$DryRun
            BackupPath = $null
            MetadataPath = $null
            Note = 'No existing phone save to back up.'
        }
    }

    if ($backupResult.Created) {
        Invoke-BridgeBackupPrune -SlotName $slotName -TargetSide 'Phone' -BackupRoot $Config.backupRoot -RetentionCount $Config.retentionCount -DryRun:$DryRun | Out-Null
    }

    $effectivePayload = New-EffectiveTransferPayload `
        -Config $Config `
        -Purpose 'usepc-effective' `
        -SlotName $slotName `
        -IncomingSlotPath $pcPath `
        -CurrentTargetSlotPath $stagedPhonePath `
        -TargetSide 'Phone'

    if (-not $DryRun) {
        Copy-LocalSaveToPhone -Config $Config -DeviceId $device.Id -LocalSlotPath $effectivePayload.Path
    }

    $verifyPath = New-StagingSlotPath -Config $Config -Purpose 'phone-verify' -SlotName $slotName
    if (-not $DryRun) {
        Copy-PhoneSaveToLocal -Config $Config -DeviceId $device.Id -SlotName $slotName -TargetPath $verifyPath | Out-Null
    }

    $verification = if ($DryRun) {
        [ordered]@{ Status = 'DryRun'; Reason = 'Verification skipped in dry-run mode.' }
    }
    else {
        $verifyComparison = Compare-SaveFolders -PCPath $effectivePayload.Path -PhonePath $verifyPath
        [ordered]@{
            Status = if ($verifyComparison.OverallStatus -eq 'Identical') { 'Succeeded' } else { 'Failed' }
            Summary = $verifyComparison.Summary
        }
    }

    if ($verification.Status -eq 'Failed') {
        throw 'Verification failed after copying the PC save to the phone.'
    }

    $RunRecord.selectedSaveSlot = $slotName
    $RunRecord.connectedDeviceId = $device.Id
    $RunRecord.detectedPaths = [ordered]@{
        pcRoot = $pcRoot
        pcSlot = $pcPath
        phoneSlot = $androidSaveRoot.TrimEnd('/') + '/' + $slotName
        stagingPhoneSlot = $stagedPhonePath
        effectivePayload = $effectivePayload.Path
        verificationSlot = $verifyPath
    }
    $RunRecord.compatibility = $compatibility
    $RunRecord.backupResult = $backupResult
    $RunRecord.comparisonSummary = $comparison.Summary
    $RunRecord.overwriteTarget = 'Phone'
    $RunRecord.preservedSettings = $effectivePayload
    $RunRecord.verificationResult = $verification

    return [pscustomobject]@{
        ExitCode = 0
        FinalOutcome = if ($DryRun) { 'DryRunCompleted' } else { 'Completed' }
        Compatibility = $compatibility
        ComparisonSummary = $comparison.Summary
        OverwriteTarget = 'Phone'
        VerificationResult = $verification
        Errors = @()
        Preferences = @{ preferredSaveSlot = $slotName; preferredDeviceId = $device.Id }
        OutputLines = @(
            "Selected save slot: $slotName"
            (Get-BackupSummaryLine -BackupResult $backupResult -NoBackupNeededMessage 'No existing phone save was found, so no backup was needed.')
            (Get-TargetActionSummaryLine -Side 'Phone' -TargetExists:$phoneExists -DryRun:$DryRun)
            (Get-PreservedSettingsSummaryLine -PreservationResult $effectivePayload)
            "Compatibility: $($compatibility.Status) - $($compatibility.Reason)"
            (Get-VerificationSummaryLine -VerificationResult $verification)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
}

function Invoke-UsePhoneWorkflow {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$RequestedSaveSlot,

        [string]$RequestedDeviceId,

        [switch]$DryRun,

        [switch]$Force,

        [switch]$NonInteractive,

        [System.Collections.IDictionary]$RunRecord
    )

    $device = Resolve-SelectedDevice -Config $Config -RequestedDeviceId $RequestedDeviceId -NonInteractive:$NonInteractive
    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $device.Id

    $pcRoot = Get-WindowsSaveRoot
    $pcSlots = @(Get-LocalSaveSlots -RootPath $pcRoot -Side 'PC')
    $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
    $phoneSlotNames = @($phoneSlots | ForEach-Object { $_.Name })
    $slotName = Resolve-SelectedSaveSlot -Config $Config -RequestedSaveSlot $RequestedSaveSlot -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive:$NonInteractive
    if ($phoneSlotNames -notcontains $slotName) {
        throw "Use Phone save requires the save slot '$slotName' to exist on the phone."
    }

    $stagedPhonePath = New-StagingSlotPath -Config $Config -Purpose 'phone-selected' -SlotName $slotName
    Copy-PhoneSaveToLocal -Config $Config -DeviceId $device.Id -SlotName $slotName -TargetPath $stagedPhonePath | Out-Null

    $phoneValidation = Test-SaveFolder -FolderPath $stagedPhonePath
    if (-not $phoneValidation.IsValid -and -not ($Force -or $Config.allowUnsafeOverride)) {
        throw "The phone save '$slotName' is incomplete or unreadable."
    }

    $pcPath = Get-SlotPathByName -Slots $pcSlots -SlotName $slotName
    $comparison = Compare-SaveFolders -PCPath $pcPath -PhonePath $stagedPhonePath
    $pcGameVersion = Get-PCGameVersion -Config $Config
    $compatibility = Test-VersionCompatibility -SaveVersion $phoneValidation.SaveVersion.Parsed -TargetGameVersion $pcGameVersion.Parsed

    if ($compatibility.Status -eq 'Blocked' -and -not $Force) {
        throw "Compatibility check failed. $($compatibility.Reason)"
    }

    if (-not (Confirm-BridgeAction -Message 'Use Phone save and overwrite the PC version? A backup of the overwritten side will be created first.' -Force:$Force -NonInteractive:$NonInteractive)) {
        return [pscustomobject]@{
            ExitCode = 1
            FinalOutcome = 'Canceled'
            Compatibility = $compatibility
            ComparisonSummary = $comparison.Summary
            OverwriteTarget = 'PC'
            VerificationResult = @{}
            Errors = @()
            Preferences = @{}
            OutputLines = @('Operation canceled.')
        }
    }

    $backupResult = if ($pcPath) {
        $metadata = @{
            sourceSide = 'PC'
            targetSide = 'PC'
            saveSlot = $slotName
            operationType = 'UsePhoneSave'
            deviceId = $device.Id
        }
        New-BridgeBackup -SlotName $slotName -TargetSide 'PC' -OperationType 'UsePhoneSave' -SourcePath $pcPath -BackupRoot $Config.backupRoot -Metadata $metadata -DryRun:$DryRun
    }
    else {
        [pscustomobject]@{
            Created = $false
            DryRun = [bool]$DryRun
            BackupPath = $null
            MetadataPath = $null
            Note = 'No existing PC save to back up.'
        }
    }

    if ($backupResult.Created) {
        Invoke-BridgeBackupPrune -SlotName $slotName -TargetSide 'PC' -BackupRoot $Config.backupRoot -RetentionCount $Config.retentionCount -DryRun:$DryRun | Out-Null
    }

    $targetPcPath = Join-Path -Path $pcRoot -ChildPath $slotName
    $effectivePayload = New-EffectiveTransferPayload `
        -Config $Config `
        -Purpose 'usephone-effective' `
        -SlotName $slotName `
        -IncomingSlotPath $stagedPhonePath `
        -CurrentTargetSlotPath $pcPath `
        -TargetSide 'PC'

    if (-not $DryRun) {
        Copy-BridgeDirectory -SourcePath $effectivePayload.Path -TargetPath $targetPcPath -CleanTarget
    }

    $verification = if ($DryRun) {
        [ordered]@{ Status = 'DryRun'; Reason = 'Verification skipped in dry-run mode.' }
    }
    else {
        $verifyComparison = Compare-SaveFolders -PCPath $targetPcPath -PhonePath $effectivePayload.Path
        [ordered]@{
            Status = if ($verifyComparison.OverallStatus -eq 'Identical') { 'Succeeded' } else { 'Failed' }
            Summary = $verifyComparison.Summary
        }
    }

    if ($verification.Status -eq 'Failed') {
        throw 'Verification failed after copying the phone save to the PC.'
    }

    $RunRecord.selectedSaveSlot = $slotName
    $RunRecord.connectedDeviceId = $device.Id
    $RunRecord.detectedPaths = [ordered]@{
        pcRoot = $pcRoot
        pcSlot = $targetPcPath
        phoneSlot = $androidSaveRoot.TrimEnd('/') + '/' + $slotName
        stagingPhoneSlot = $stagedPhonePath
        effectivePayload = $effectivePayload.Path
    }
    $RunRecord.compatibility = $compatibility
    $RunRecord.backupResult = $backupResult
    $RunRecord.comparisonSummary = $comparison.Summary
    $RunRecord.overwriteTarget = 'PC'
    $RunRecord.preservedSettings = $effectivePayload
    $RunRecord.verificationResult = $verification

    return [pscustomobject]@{
        ExitCode = 0
        FinalOutcome = if ($DryRun) { 'DryRunCompleted' } else { 'Completed' }
        Compatibility = $compatibility
        ComparisonSummary = $comparison.Summary
        OverwriteTarget = 'PC'
        VerificationResult = $verification
        Errors = @()
        Preferences = @{ preferredSaveSlot = $slotName; preferredDeviceId = $device.Id }
        OutputLines = @(
            "Selected save slot: $slotName"
            (Get-BackupSummaryLine -BackupResult $backupResult -NoBackupNeededMessage 'No existing PC save was found, so no backup was needed.')
            (Get-TargetActionSummaryLine -Side 'PC' -TargetExists:([bool]$pcPath) -DryRun:$DryRun)
            (Get-PreservedSettingsSummaryLine -PreservationResult $effectivePayload)
            "Compatibility: $($compatibility.Status) - $($compatibility.Reason)"
            (Get-VerificationSummaryLine -VerificationResult $verification)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
}

function Invoke-RestoreWorkflow {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$RequestedSaveSlot,

        [string]$RequestedDeviceId,

        [string]$BackupId,

        [ValidateSet('PC', 'Phone')]
        [string]$RestoreTarget,

        [switch]$DryRun,

        [switch]$Force,

        [switch]$NonInteractive,

        [System.Collections.IDictionary]$RunRecord
    )

    $backupSlots = @(Get-BackupSlotNames -BackupRoot $Config.backupRoot)
    if ($backupSlots.Count -eq 0) {
        throw 'No backups are available.'
    }

    $slotName = if ($RequestedSaveSlot) {
        if ($backupSlots -notcontains $RequestedSaveSlot) {
            throw "No backups were found for save slot '$RequestedSaveSlot'."
        }
        $RequestedSaveSlot
    }
    else {
        $items = $backupSlots | ForEach-Object { [pscustomobject]@{ Name = $_ } }
        (Select-BridgeItem -Items $items -Title 'Choose a save slot to restore' -LabelScript { param($item) $item.Name } -UiMode $Config.uiMode -NonInteractive:$NonInteractive).Name
    }

    $backups = @(Get-BridgeBackups -SlotName $slotName -BackupRoot $Config.backupRoot)
    if ($BackupId) {
        $backup = $backups | Where-Object { $_.Id -eq $BackupId } | Select-Object -First 1
        if (-not $backup) {
            throw "Backup '$BackupId' was not found for slot '$slotName'."
        }
    }
    elseif ($backups.Count -eq 1) {
        $backup = $backups[0]
    }
    else {
        $backup = Select-BridgeItem -Items $backups -Title 'Choose a backup to restore' -LabelScript {
            param($item)
            $createdAt = if ($item.Metadata) { $item.Metadata.createdAt } else { $item.Id }
            '{0} | {1} | {2}' -f $item.Id, $item.TargetSide, $createdAt
        } -UiMode $Config.uiMode -NonInteractive:$NonInteractive
    }

    $targetSide = if ($RestoreTarget) {
        $RestoreTarget
    }
    else {
        $options = @(
            [pscustomobject]@{ Value = 'PC'; Label = 'Restore to PC' },
            [pscustomobject]@{ Value = 'Phone'; Label = 'Restore to Phone' }
        )
        (Select-BridgeItem -Items $options -Title 'Choose a restore target' -LabelScript { param($item) $item.Label } -UiMode $Config.uiMode -NonInteractive:$NonInteractive).Value
    }

    if (-not (Confirm-BridgeAction -Message "Restore backup $($backup.Id) to $($targetSide)? A backup of the overwritten side will be created first." -Force:$Force -NonInteractive:$NonInteractive)) {
        return [pscustomobject]@{
            ExitCode = 1
            FinalOutcome = 'Canceled'
            Compatibility = @{}
            ComparisonSummary = @{}
            OverwriteTarget = $targetSide
            VerificationResult = @{}
            Errors = @()
            Preferences = @{}
            OutputLines = @('Operation canceled.')
        }
    }

    $device = $null
    if ($targetSide -eq 'Phone') {
        $device = Resolve-SelectedDevice -Config $Config -RequestedDeviceId $RequestedDeviceId -NonInteractive:$NonInteractive
        $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $device.Id
    }

    $pcRoot = Get-WindowsSaveRoot
    $targetPath = if ($targetSide -eq 'PC') {
        Join-Path -Path $pcRoot -ChildPath $slotName
    }
    else {
        $androidSaveRoot.TrimEnd('/') + '/' + $slotName
    }

    $currentTargetPath = $null
    if ($targetSide -eq 'PC' -and (Test-Path -LiteralPath $targetPath)) {
        $currentTargetPath = $targetPath
    }
    elseif ($targetSide -eq 'Phone') {
        $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
        $phoneSlotNames = @($phoneSlots | ForEach-Object { $_.Name })
        if ($phoneSlotNames -contains $slotName) {
            $currentTargetPath = New-StagingSlotPath -Config $Config -Purpose 'restore-phone-current' -SlotName $slotName
            Copy-PhoneSaveToLocal -Config $Config -DeviceId $device.Id -SlotName $slotName -TargetPath $currentTargetPath | Out-Null
        }
    }

    $preRestoreBackup = if ($currentTargetPath) {
        $metadata = @{
            sourceSide = $targetSide
            targetSide = $targetSide
            saveSlot = $slotName
            operationType = 'RestoreBackup'
            deviceId = if ($device) { $device.Id } else { $null }
        }
        New-BridgeBackup -SlotName $slotName -TargetSide $targetSide -OperationType 'RestoreBackup' -SourcePath $currentTargetPath -BackupRoot $Config.backupRoot -Metadata $metadata -DryRun:$DryRun
    }
    else {
        [pscustomobject]@{
            Created = $false
            DryRun = [bool]$DryRun
            BackupPath = $null
            MetadataPath = $null
            Note = 'No existing target save to back up before restore.'
        }
    }

    if ($preRestoreBackup.Created) {
        Invoke-BridgeBackupPrune -SlotName $slotName -TargetSide $targetSide -BackupRoot $Config.backupRoot -RetentionCount $Config.retentionCount -DryRun:$DryRun | Out-Null
    }

    $effectivePayload = New-EffectiveTransferPayload `
        -Config $Config `
        -Purpose ('restore-{0}-effective' -f $targetSide.ToLowerInvariant()) `
        -SlotName $slotName `
        -IncomingSlotPath $backup.ContentPath `
        -CurrentTargetSlotPath $currentTargetPath `
        -TargetSide $targetSide

    if (-not $DryRun) {
        if ($targetSide -eq 'PC') {
            Copy-BridgeDirectory -SourcePath $effectivePayload.Path -TargetPath $targetPath -CleanTarget
        }
        else {
            Copy-LocalSaveToPhone -Config $Config -DeviceId $device.Id -LocalSlotPath $effectivePayload.Path
        }
    }

    $verification = if ($DryRun) {
        [ordered]@{ Status = 'DryRun'; Reason = 'Verification skipped in dry-run mode.' }
    }
    elseif ($targetSide -eq 'PC') {
        $verifyComparison = Compare-SaveFolders -PCPath $targetPath -PhonePath $effectivePayload.Path
        [ordered]@{
            Status = if ($verifyComparison.OverallStatus -eq 'Identical') { 'Succeeded' } else { 'Failed' }
            Summary = $verifyComparison.Summary
        }
    }
    else {
        $verifyPath = New-StagingSlotPath -Config $Config -Purpose 'restore-phone-verify' -SlotName $slotName
        Copy-PhoneSaveToLocal -Config $Config -DeviceId $device.Id -SlotName $slotName -TargetPath $verifyPath | Out-Null
        $verifyComparison = Compare-SaveFolders -PCPath $effectivePayload.Path -PhonePath $verifyPath
        [ordered]@{
            Status = if ($verifyComparison.OverallStatus -eq 'Identical') { 'Succeeded' } else { 'Failed' }
            Summary = $verifyComparison.Summary
        }
    }

    if ($verification.Status -eq 'Failed') {
        throw 'Verification failed after restoring the backup.'
    }

    $RunRecord.selectedSaveSlot = $slotName
    $RunRecord.connectedDeviceId = if ($device) { $device.Id } else { '' }
    $RunRecord.detectedPaths = [ordered]@{
        backupContent = $backup.ContentPath
        target = $targetPath
        effectivePayload = $effectivePayload.Path
    }
    $RunRecord.backupResult = $preRestoreBackup
    $RunRecord.overwriteTarget = $targetSide
    $RunRecord.preservedSettings = $effectivePayload
    $RunRecord.verificationResult = $verification

    return [pscustomobject]@{
        ExitCode = 0
        FinalOutcome = if ($DryRun) { 'DryRunCompleted' } else { 'Completed' }
        Compatibility = @{}
        ComparisonSummary = @{}
        OverwriteTarget = $targetSide
        VerificationResult = $verification
        Errors = @()
        Preferences = @{ preferredSaveSlot = $slotName; preferredDeviceId = if ($device) { $device.Id } else { $Config.preferredDeviceId } }
        OutputLines = @(
            "Selected save slot: $slotName"
            "Restore target: $targetSide"
            (Get-BackupSummaryLine -BackupResult $preRestoreBackup -NoBackupNeededMessage 'No existing target save was found, so no backup was needed before restore.')
            (Get-TargetActionSummaryLine -Side $targetSide -TargetExists:([bool]$currentTargetPath) -DryRun:$DryRun)
            (Get-PreservedSettingsSummaryLine -PreservationResult $effectivePayload)
            (Get-VerificationSummaryLine -VerificationResult $verification)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
}

function Invoke-BridgeAction {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$Action,

        [string]$SaveSlot,

        [string]$DeviceId,

        [string]$BackupId,

        [ValidateSet('PC', 'Phone')]
        [string]$RestoreTarget,

        [switch]$DryRun,

        [switch]$Force,

        [switch]$NonInteractive,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$RunRecord
    )

    Ensure-BridgeDirectory -Path $Config.backupRoot | Out-Null
    Ensure-BridgeDirectory -Path $Config.stagingDirectory | Out-Null
    Ensure-BridgeDirectory -Path $Config.logRoot | Out-Null

    Warn-IfStardewRunning

    if (-not $Action) {
        $Action = Get-MainMenuAction -Config $Config
    }

    if ($Action -eq 'Exit') {
        return [pscustomobject]@{
            ExitCode = 0
            FinalOutcome = 'Exited'
            Compatibility = @{}
            ComparisonSummary = @{}
            OverwriteTarget = ''
            VerificationResult = @{}
            Errors = @()
            Preferences = @{}
            OutputLines = @('Exited without changes.')
        }
    }

    switch ($Action) {
        'Inspect' {
            return Invoke-InspectWorkflow -Config $Config -RequestedSaveSlot $SaveSlot -RequestedDeviceId $DeviceId -NonInteractive:$NonInteractive -RunRecord $RunRecord
        }
        'UsePC' {
            return Invoke-UsePCWorkflow -Config $Config -RequestedSaveSlot $SaveSlot -RequestedDeviceId $DeviceId -DryRun:$DryRun -Force:$Force -NonInteractive:$NonInteractive -RunRecord $RunRecord
        }
        'UsePhone' {
            return Invoke-UsePhoneWorkflow -Config $Config -RequestedSaveSlot $SaveSlot -RequestedDeviceId $DeviceId -DryRun:$DryRun -Force:$Force -NonInteractive:$NonInteractive -RunRecord $RunRecord
        }
        'RestoreBackup' {
            return Invoke-RestoreWorkflow -Config $Config -RequestedSaveSlot $SaveSlot -RequestedDeviceId $DeviceId -BackupId $BackupId -RestoreTarget $RestoreTarget -DryRun:$DryRun -Force:$Force -NonInteractive:$NonInteractive -RunRecord $RunRecord
        }
        default {
            throw "Unsupported action '$Action'."
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-BridgeAction'
)
