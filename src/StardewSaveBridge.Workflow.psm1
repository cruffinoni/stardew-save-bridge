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
        [pscustomobject]@{ Value = 'Daemon'; Label = $labels.RunSyncDaemon },
        [pscustomobject]@{ Value = 'Exit'; Label = $labels.Exit }
    )

    $selected = Select-BridgeItem -Items $items -Title 'Choose an action' -LabelScript { param($item) $item.Label } -UiMode $Config.uiMode
    return $selected.Value
}

function ConvertTo-BridgeUsbDevice {
    param(
        [Parameter(Mandatory)]
        $Device
    )

    return [pscustomobject]@{
        Id = $Device.Id
        State = $Device.State
        DiscoverySource = 'USB'
        ServiceName = ''
        ServiceType = ''
        Address = ''
        Port = 0
        DisplayName = $Device.Id
        SelectionReason = ''
    }
}

function Set-BridgeDeviceSelectionReason {
    param(
        [Parameter(Mandatory)]
        $Device,

        [Parameter(Mandatory)]
        [string]$SelectionReason
    )

    $copy = [ordered]@{}
    foreach ($property in $Device.PSObject.Properties) {
        $copy[$property.Name] = $property.Value
    }

    $copy['SelectionReason'] = $SelectionReason
    return [pscustomobject]$copy
}

function Get-BridgeDevicePickerLabel {
    param(
        [Parameter(Mandatory)]
        $Device
    )

    $source = if ($Device.DiscoverySource -eq 'mDNS') { 'mDNS' } else { 'USB' }
    return '{0} [{1}] via {2}' -f $Device.DisplayName, $Device.State, $source
}

function Get-BridgeDeviceSelectionSummaryLine {
    param(
        [Parameter(Mandatory)]
        $Device
    )

    $source = if ($Device.DiscoverySource -eq 'mDNS') { 'mDNS' } else { 'USB fallback' }
    $suffix = if ($Device.SelectionReason -eq 'AutoSelectedMdns') { ' (auto-selected)' } else { '' }
    return 'Selected device: {0} via {1}{2}' -f $Device.DisplayName, $source, $suffix
}

function Get-BridgeObjectPropertyValue {
    param(
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Merge-BridgePreferenceUpdates {
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$BasePreferences,

        [AllowNull()]
        [System.Collections.IDictionary]$AdditionalPreferences
    )

    $merged = @{}

    if ($BasePreferences) {
        foreach ($key in $BasePreferences.Keys) {
            $merged[$key] = $BasePreferences[$key]
        }
    }

    if ($AdditionalPreferences) {
        foreach ($key in $AdditionalPreferences.Keys) {
            $merged[$key] = $AdditionalPreferences[$key]
        }
    }

    return $merged
}

function Get-PCGameVersionPreferenceUpdate {
    param(
        [AllowNull()]
        $PcGameVersion
    )

    $shouldPersist = Get-BridgeObjectPropertyValue -InputObject $PcGameVersion -Name 'ShouldPersist'
    $resolvedPath = Get-BridgeObjectPropertyValue -InputObject $PcGameVersion -Name 'ResolvedPath'
    if ($shouldPersist -and -not [string]::IsNullOrWhiteSpace($resolvedPath)) {
        return @{ pcGameExePath = $resolvedPath }
    }

    return @{}
}

function Get-PCGameVersionMessage {
    param(
        [AllowNull()]
        $PcGameVersion
    )

    $message = Get-BridgeObjectPropertyValue -InputObject $PcGameVersion -Name 'Message'
    if ([string]::IsNullOrWhiteSpace($message)) {
        return $null
    }

    return $message
}

function Get-PCGameVersionSummaryLine {
    param(
        [AllowNull()]
        $PcGameVersion
    )

    $parsedVersion = Get-BridgeObjectPropertyValue -InputObject $PcGameVersion -Name 'Parsed'
    if (-not $parsedVersion) {
        return $null
    }

    return 'Detected PC game version: {0}' -f $parsedVersion.ToString()
}

function Get-PhoneGameVersionSummaryLine {
    param(
        [AllowNull()]
        $PhoneGameVersion
    )

    $parsedVersion = Get-BridgeObjectPropertyValue -InputObject $PhoneGameVersion -Name 'Parsed'
    if (-not $parsedVersion) {
        return $null
    }

    return 'Detected Phone game version: {0}' -f $parsedVersion.ToString()
}

function Test-ShouldStopDaemonForUnknownPcVersion {
    param(
        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$RunRecord
    )

    $pcGameVersion = Get-BridgeObjectPropertyValue -InputObject $Result.Compatibility -Name 'pcGameVersion'
    if ($pcGameVersion) {
        return $false
    }

    $syncResults = @($RunRecord.syncResults)
    if ($syncResults.Count -eq 0) {
        return $false
    }

    return (@($syncResults | Where-Object { $_.Status -eq 'SkippedCompatibility' -and $_.TargetSide -eq 'PC' }).Count -gt 0)
}

function Set-BridgeRunRecordSelectedDevice {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$RunRecord,

        [Parameter(Mandatory)]
        $Device
    )

    $endpoint = ''
    if (-not [string]::IsNullOrWhiteSpace($Device.Address) -and $Device.Port -gt 0) {
        $endpoint = '{0}:{1}' -f $Device.Address, $Device.Port
    }

    $RunRecord.connectedDeviceId = $Device.Id
    $RunRecord.cycleDeviceEndpoint = $endpoint
    $RunRecord['deviceSelection'] = [ordered]@{
        message = Get-BridgeDeviceSelectionSummaryLine -Device $Device
        source = $Device.DiscoverySource
        selectionReason = $Device.SelectionReason
        label = Get-BridgeDevicePickerLabel -Device $Device
        displayName = $Device.DisplayName
        serviceName = $Device.ServiceName
        serviceType = $Device.ServiceType
        address = $Device.Address
        port = $Device.Port
        deviceId = $Device.Id
    }
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

    $mdnsDevices = @(Get-AdbMdnsDeviceList -Config $Config)
    $usbDevices = @(Get-AdbDeviceList -Config $Config | ForEach-Object { ConvertTo-BridgeUsbDevice -Device $_ })
    $allDevices = @()
    $seenIds = @{}
    foreach ($device in @($mdnsDevices + $usbDevices)) {
        if ($seenIds.ContainsKey($device.Id)) {
            continue
        }

        $seenIds[$device.Id] = $true
        $allDevices += $device
    }

    if ($allDevices.Count -eq 0) {
        throw 'No Android device is connected.'
    }

    if ($RequestedDeviceId) {
        $requested = $allDevices | Where-Object { $_.Id -eq $RequestedDeviceId } | Select-Object -First 1
        if (-not $requested) {
            throw "Requested device '$RequestedDeviceId' is not connected."
        }

        if ($requested.State -eq 'unauthorized') {
            throw 'An Android device is connected but unauthorized. Unlock the phone and allow USB debugging.'
        }

        if ($requested.State -ne 'device') {
            throw 'No authorized Android device is available.'
        }

        return Set-BridgeDeviceSelectionReason -Device $requested -SelectionReason 'RequestedDeviceId'
    }

    if ($Config.preferredDeviceId) {
        $preferred = $allDevices | Where-Object { $_.Id -eq $Config.preferredDeviceId -and $_.State -eq 'device' } | Select-Object -First 1
        if ($preferred) {
            return Set-BridgeDeviceSelectionReason -Device $preferred -SelectionReason 'PreferredDeviceId'
        }
    }

    $onlineMdns = @($mdnsDevices | Where-Object { $_.State -eq 'device' })
    if ($onlineMdns.Count -gt 0) {
        return Set-BridgeDeviceSelectionReason -Device $onlineMdns[0] -SelectionReason 'AutoSelectedMdns'
    }

    $unauthorized = @($allDevices | Where-Object { $_.State -eq 'unauthorized' })
    $onlineUsb = @($usbDevices | Where-Object { $_.State -eq 'device' })
    if ($onlineUsb.Count -eq 0) {
        if ($unauthorized.Count -gt 0) {
            throw 'An Android device is connected but unauthorized. Unlock the phone and allow USB debugging.'
        }

        throw 'No authorized Android device is available.'
    }

    if ($onlineUsb.Count -eq 1) {
        return Set-BridgeDeviceSelectionReason -Device $onlineUsb[0] -SelectionReason 'UsbFallback'
    }

    $selected = Select-BridgeItem -Items $onlineUsb -Title 'Choose a phone device' -LabelScript { param($item) Get-BridgeDevicePickerLabel -Device $item } -UiMode $Config.uiMode -NonInteractive:$NonInteractive
    return Set-BridgeDeviceSelectionReason -Device $selected -SelectionReason 'UsbPromptSelection'
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

function Get-AllSaveSlotNames {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$PcSlots,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$PhoneSlots
    )

    return @(
        @($PcSlots | ForEach-Object { $_.Name }) +
        @($PhoneSlots | ForEach-Object { $_.Name }) |
        Sort-Object -Unique |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-LatestLocalSaveSlotName {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Slots
    )

    $ranked = foreach ($slot in $Slots) {
        $latestWriteTime = $null
        if ($slot.Path -and (Test-Path -LiteralPath $slot.Path -PathType Container)) {
            $latestWriteTime = (Test-SaveFolder -FolderPath $slot.Path -SkipXmlCheck).LatestWriteTimeUtc
        }

        [pscustomobject]@{
            Name = $slot.Name
            LatestWriteTimeUtc = $latestWriteTime
        }
    }

    return ($ranked |
        Sort-Object -Property @{ Expression = { if ($_.LatestWriteTimeUtc) { $_.LatestWriteTimeUtc } else { [datetime]::MinValue } }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false } |
        Select-Object -First 1 -ExpandProperty Name)
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
        $NewerSideHint
    )

    if ($OverallStatus -eq 'Identical') {
        return 'Saves are identical. No handoff is needed.'
    }

    $message = if ($NewerSideHint -and -not [string]::IsNullOrWhiteSpace($NewerSideHint.Message)) {
        $NewerSideHint.Message.Trim()
    }
    else {
        $null
    }

    switch ($NewerSideHint.Hint) {
        'PC' { return '{0} Choose the version you want to keep.' -f $message }
        'Phone' { return '{0} Choose the version you want to keep.' -f $message }
        default {
            if ($message) {
                return '{0} Review the comparison before choosing the version you want to keep.' -f $message
            }

            return 'Review the comparison before choosing the version you want to keep.'
        }
    }
}

function Join-SelectionReason {
    param(
        [AllowNull()]
        [string]$SelectionMessage,

        [Parameter(Mandatory)]
        [string]$OutcomeMessage
    )

    if ([string]::IsNullOrWhiteSpace($SelectionMessage)) {
        return $OutcomeMessage
    }

    return '{0} {1}' -f $SelectionMessage.Trim(), $OutcomeMessage
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

function Get-DaemonSlotSummaryLine {
    param(
        [Parameter(Mandatory)]
        $SyncResult
    )

    $slotName = if ([string]::IsNullOrWhiteSpace($SyncResult.SlotName)) { 'unknown-slot' } else { $SyncResult.SlotName }
    $prefix = "Slot ${slotName}:"

    switch ($SyncResult.Status) {
        'Synced' {
            $direction = if ($SyncResult.SourceSide -and $SyncResult.TargetSide) {
                '{0} -> {1}' -f $SyncResult.SourceSide, $SyncResult.TargetSide
            }
            else {
                'updated'
            }

            $detail = if ($SyncResult.Reason) { $SyncResult.Reason } else { 'Synchronization completed.' }
            return "$prefix Synced $direction - $detail"
        }
        'AlreadySynced' {
            $detail = if ($SyncResult.Reason) { $SyncResult.Reason } else { 'The PC and phone saves are already identical.' }
            return "$prefix Already synced - $detail"
        }
        default {
            $statusText = $SyncResult.Status
            $statusText = $statusText -creplace '^Skipped', 'Skipped '
            $detail = if ($SyncResult.Reason) { $SyncResult.Reason } else { 'No additional detail was recorded.' }
            return "$prefix $statusText - $detail"
        }
    }
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

function Test-StardewRunning {
    $candidates = @('Stardew Valley', 'StardewValley')
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $candidates -contains $_.ProcessName })
    return ($running.Count -gt 0)
}

function Warn-IfStardewRunning {
    if (Test-StardewRunning) {
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
    Set-BridgeRunRecordSelectedDevice -RunRecord $RunRecord -Device $device

    $pcRoot = Get-WindowsSaveRoot
    $pcSlots = @(Get-LocalSaveSlots -RootPath $pcRoot -Side 'PC')
    $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
    $phoneSlotNames = @($phoneSlots | ForEach-Object { $_.Name })
    $effectiveRequestedSaveSlot = $RequestedSaveSlot
    if (-not $effectiveRequestedSaveSlot -and $NonInteractive -and $pcSlots.Count -gt 0) {
        $effectiveRequestedSaveSlot = Get-LatestLocalSaveSlotName -Slots $pcSlots
    }
    $slotName = Resolve-SelectedSaveSlot -Config $Config -RequestedSaveSlot $effectiveRequestedSaveSlot -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive:$NonInteractive

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
    $pcGameVersionMessage = Get-PCGameVersionMessage -PcGameVersion $pcGameVersion
    $compatibility = Get-CompatibilitySummary `
        -PcSaveVersion $(if ($pcValidation) { $pcValidation.SaveVersion.Parsed } else { $null }) `
        -PhoneSaveVersion $(if ($phoneValidation) { $phoneValidation.SaveVersion.Parsed } else { $null }) `
        -PcGameVersion $pcGameVersion.Parsed `
        -PhoneGameVersion $phoneGameVersion.Parsed

    if (-not $pcGameVersion.Parsed -and -not [string]::IsNullOrWhiteSpace($pcGameVersionMessage)) {
        $compatibility.phoneToPc = [pscustomobject]@{
            Status = 'Unknown'
            Reason = $pcGameVersionMessage
        }
    }

    $recommendation = Get-InspectRecommendation -OverallStatus $comparison.OverallStatus -NewerSideHint $comparison.NewerSideHint

    $statusLabel = if ($comparison.OverallStatus -eq 'Identical') { (Get-BridgeUiLabels).SavesAreIdentical } else { (Get-BridgeUiLabels).SavesDiffer }

    $RunRecord.selectedSaveSlot = $slotName
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
        Preferences = Merge-BridgePreferenceUpdates `
            -BasePreferences @{ preferredSaveSlot = $slotName; preferredDeviceId = $device.Id } `
            -AdditionalPreferences (Get-PCGameVersionPreferenceUpdate -PcGameVersion $pcGameVersion)
        OutputLines = @(
            (Get-BridgeDeviceSelectionSummaryLine -Device $device)
            "Selected save slot: $slotName"
            "PC path: $pcPath"
            "Phone path: $($androidSaveRoot.TrimEnd('/') + '/' + $slotName)"
            "File comparison: $statusLabel"
            "Only on PC: $($comparison.Summary.onlyOnPC)"
            "Only on Phone: $($comparison.Summary.onlyOnPhone)"
            "Content differs: $($comparison.Summary.contentDiffers)"
            "Selection reason: $($comparison.NewerSideHint.Message)"
            "PC save version: $($compatibility.pcSaveVersion)"
            "Phone save version: $($compatibility.phoneSaveVersion)"
            (Get-PCGameVersionSummaryLine -PcGameVersion $pcGameVersion)
            (Get-PhoneGameVersionSummaryLine -PhoneGameVersion $phoneGameVersion)
            $pcGameVersionMessage
            "PC to Phone: $($compatibility.pcToPhone.Status) - $($compatibility.pcToPhone.Reason)"
            "Phone to PC: $($compatibility.phoneToPc.Status) - $($compatibility.phoneToPc.Reason)"
            $recommendation
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
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
    Set-BridgeRunRecordSelectedDevice -RunRecord $RunRecord -Device $device

    $pcRoot = Get-WindowsSaveRoot
    $pcSlots = @(Get-LocalSaveSlots -RootPath $pcRoot -Side 'PC')
    $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
    $phoneSlotNames = @($phoneSlots | ForEach-Object { $_.Name })
    $effectiveRequestedSaveSlot = $RequestedSaveSlot
    if (-not $effectiveRequestedSaveSlot -and $NonInteractive -and $pcSlots.Count -gt 0) {
        $effectiveRequestedSaveSlot = Get-LatestLocalSaveSlotName -Slots $pcSlots
    }
    $slotName = Resolve-SelectedSaveSlot -Config $Config -RequestedSaveSlot $effectiveRequestedSaveSlot -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive:$NonInteractive
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
            (Get-BridgeDeviceSelectionSummaryLine -Device $device)
            "Selected save slot: $slotName"
            (Get-BackupSummaryLine -BackupResult $backupResult -NoBackupNeededMessage 'No existing phone save was found, so no backup was needed.')
            (Get-TargetActionSummaryLine -Side 'Phone' -TargetExists:$phoneExists -DryRun:$DryRun)
            (Get-PreservedSettingsSummaryLine -PreservationResult $effectivePayload)
            (Get-PhoneGameVersionSummaryLine -PhoneGameVersion $phoneGameVersion)
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
    Set-BridgeRunRecordSelectedDevice -RunRecord $RunRecord -Device $device

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
    $pcGameVersionMessage = Get-PCGameVersionMessage -PcGameVersion $pcGameVersion
    if (-not $pcGameVersion.Parsed) {
        throw $(if ($pcGameVersionMessage) { $pcGameVersionMessage } else { 'PC game version could not be determined.' })
    }

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
        Preferences = Merge-BridgePreferenceUpdates `
            -BasePreferences @{ preferredSaveSlot = $slotName; preferredDeviceId = $device.Id } `
            -AdditionalPreferences (Get-PCGameVersionPreferenceUpdate -PcGameVersion $pcGameVersion)
        OutputLines = @(
            (Get-BridgeDeviceSelectionSummaryLine -Device $device)
            "Selected save slot: $slotName"
            (Get-BackupSummaryLine -BackupResult $backupResult -NoBackupNeededMessage 'No existing PC save was found, so no backup was needed.')
            (Get-TargetActionSummaryLine -Side 'PC' -TargetExists:([bool]$pcPath) -DryRun:$DryRun)
            (Get-PreservedSettingsSummaryLine -PreservationResult $effectivePayload)
            (Get-PCGameVersionSummaryLine -PcGameVersion $pcGameVersion)
            $pcGameVersionMessage
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
        Set-BridgeRunRecordSelectedDevice -RunRecord $RunRecord -Device $device
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
            $(if ($device) { Get-BridgeDeviceSelectionSummaryLine -Device $device } else { $null })
            "Selected save slot: $slotName"
            "Restore target: $targetSide"
            (Get-BackupSummaryLine -BackupResult $preRestoreBackup -NoBackupNeededMessage 'No existing target save was found, so no backup was needed before restore.')
            (Get-TargetActionSummaryLine -Side $targetSide -TargetExists:([bool]$currentTargetPath) -DryRun:$DryRun)
            (Get-PreservedSettingsSummaryLine -PreservationResult $effectivePayload)
            (Get-VerificationSummaryLine -VerificationResult $verification)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
}

function Get-DaemonIntervalSeconds {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $minutes = 0
    if (-not [int]::TryParse([string]$Config.daemonIntervalMinutes, [ref]$minutes) -or $minutes -lt 1) {
        throw 'daemonIntervalMinutes must be configured as a positive integer.'
    }

    return ($minutes * 60)
}

function Wait-BridgeDaemonInterval {
    param(
        [Parameter(Mandatory)]
        [int]$Seconds
    )

    Start-Sleep -Seconds $Seconds
}

function Invoke-DaemonSlotSync {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DeviceId,

        [Parameter(Mandatory)]
        [string]$AndroidSaveRoot,

        [Parameter(Mandatory)]
        [string]$SlotName,

        [AllowNull()]
        [string]$PcPath,

        [AllowNull()]
        [pscustomobject]$PcGameVersion,

        [AllowNull()]
        [pscustomobject]$PhoneGameVersion,

        [switch]$DryRun
    )

    $result = [ordered]@{
        SlotName = $SlotName
        Status = 'Unknown'
        SourceSide = $null
        TargetSide = $null
        Reason = $null
        ComparisonSummary = @{}
        Compatibility = @{}
        BackupResult = @{}
        PreservedSettings = @{}
        VerificationResult = @{}
        DetectedPaths = @{}
    }

    try {
        $stagedPhonePath = $null
        $phoneExists = $false
        if (-not [string]::IsNullOrWhiteSpace($AndroidSaveRoot)) {
            $phoneExists = (@(Get-PhoneSaveSlots -Config $Config -DeviceId $DeviceId | Where-Object { $_.Name -eq $SlotName }).Count -gt 0)
        }

        if ($phoneExists) {
            $stagedPhonePath = New-StagingSlotPath -Config $Config -Purpose 'daemon-phone-current' -SlotName $SlotName
            Copy-PhoneSaveToLocal -Config $Config -DeviceId $DeviceId -SlotName $SlotName -TargetPath $stagedPhonePath | Out-Null
        }

        $pcValidation = if ($PcPath) { Test-SaveFolder -FolderPath $PcPath } else { $null }
        $phoneValidation = if ($stagedPhonePath) { Test-SaveFolder -FolderPath $stagedPhonePath } else { $null }
        $comparison = Compare-SaveFolders -PCPath $PcPath -PhonePath $stagedPhonePath
        $result.ComparisonSummary = $comparison.Summary
        $result.DetectedPaths = [ordered]@{
            pcSlot = $PcPath
            phoneSlot = if ($phoneExists) { $AndroidSaveRoot.TrimEnd('/') + '/' + $SlotName } else { $null }
            stagingPhoneSlot = $stagedPhonePath
        }

        if ($PcPath -and $stagedPhonePath -and $comparison.OverallStatus -eq 'Identical') {
            $result.Status = 'AlreadySynced'
            $result.Reason = 'The PC and phone saves are already identical.'
            return [pscustomobject]$result
        }

        $sourceSide = $null
        $targetSide = $null
        switch ($comparison.NewerSideHint.Hint) {
            'PC' {
                if ($PcPath) {
                    $sourceSide = 'PC'
                    $targetSide = 'Phone'
                }
            }
            'Phone' {
                if ($stagedPhonePath) {
                    $sourceSide = 'Phone'
                    $targetSide = 'PC'
                }
            }
        }

        if (-not $sourceSide) {
            if ($PcPath -and -not $stagedPhonePath) {
                $sourceSide = 'PC'
                $targetSide = 'Phone'
            }
            elseif ($stagedPhonePath -and -not $PcPath) {
                $sourceSide = 'Phone'
                $targetSide = 'PC'
            }
        }

        $selectionMessage = if ($comparison.NewerSideHint -and -not [string]::IsNullOrWhiteSpace($comparison.NewerSideHint.Message)) {
            $comparison.NewerSideHint.Message
        }
        else {
            $null
        }

        if (-not $sourceSide) {
            $result.Status = 'SkippedAmbiguous'
            $result.Reason = if ($selectionMessage) { $selectionMessage } else { 'The newer side could not be determined safely.' }
            return [pscustomobject]$result
        }

        $result.SourceSide = $sourceSide
        $result.TargetSide = $targetSide
        $pcGameVersionMessage = Get-PCGameVersionMessage -PcGameVersion $PcGameVersion

        if ($sourceSide -eq 'PC') {
            if (-not $pcValidation -or -not $pcValidation.IsValid) {
                $result.Status = 'SkippedInvalidSource'
                $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage "The PC save '$SlotName' is incomplete or unreadable."
                return [pscustomobject]$result
            }

            $compatibility = Test-VersionCompatibility -SaveVersion $pcValidation.SaveVersion.Parsed -TargetGameVersion $PhoneGameVersion.Parsed
            $result.Compatibility = $compatibility
            if ($compatibility.Status -ne 'Safe') {
                $result.Status = 'SkippedCompatibility'
                $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage $compatibility.Reason
                return [pscustomobject]$result
            }

            $backupResult = if ($stagedPhonePath) {
                $metadata = @{
                    sourceSide = 'Phone'
                    targetSide = 'Phone'
                    saveSlot = $SlotName
                    operationType = 'DaemonSync'
                    deviceId = $DeviceId
                }
                New-BridgeBackup -SlotName $SlotName -TargetSide 'Phone' -OperationType 'DaemonSync' -SourcePath $stagedPhonePath -BackupRoot $Config.backupRoot -Metadata $metadata -DryRun:$DryRun
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
                Invoke-BridgeBackupPrune -SlotName $SlotName -TargetSide 'Phone' -BackupRoot $Config.backupRoot -RetentionCount $Config.retentionCount -DryRun:$DryRun | Out-Null
            }

            $effectivePayload = New-EffectiveTransferPayload -Config $Config -Purpose 'daemon-usepc-effective' -SlotName $SlotName -IncomingSlotPath $PcPath -CurrentTargetSlotPath $stagedPhonePath -TargetSide 'Phone'
            if (-not $DryRun) {
                Copy-LocalSaveToPhone -Config $Config -DeviceId $DeviceId -LocalSlotPath $effectivePayload.Path | Out-Null
            }

            $verifyPath = New-StagingSlotPath -Config $Config -Purpose 'daemon-phone-verify' -SlotName $SlotName
            if (-not $DryRun) {
                Copy-PhoneSaveToLocal -Config $Config -DeviceId $DeviceId -SlotName $SlotName -TargetPath $verifyPath | Out-Null
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

            $result.Status = 'Synced'
            $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage 'Copied the PC save to the phone and verified the result.'
            $result.BackupResult = $backupResult
            $result.PreservedSettings = $effectivePayload
            $result.VerificationResult = $verification
            $result.DetectedPaths['effectivePayload'] = $effectivePayload.Path
            return [pscustomobject]$result
        }

        if (-not $PcGameVersion.Parsed) {
            $reason = if ($pcGameVersionMessage) { $pcGameVersionMessage } else { 'PC game version could not be determined.' }
            $result.Compatibility = [pscustomobject]@{
                Status = 'Unknown'
                Reason = $reason
            }
            $result.Status = 'SkippedCompatibility'
            $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage $reason
            return [pscustomobject]$result
        }

        if (-not $phoneValidation -or -not $phoneValidation.IsValid) {
            $result.Status = 'SkippedInvalidSource'
            $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage "The phone save '$SlotName' is incomplete or unreadable."
            return [pscustomobject]$result
        }

        $compatibility = Test-VersionCompatibility -SaveVersion $phoneValidation.SaveVersion.Parsed -TargetGameVersion $PcGameVersion.Parsed
        $result.Compatibility = $compatibility
        if ($compatibility.Status -ne 'Safe') {
            $result.Status = 'SkippedCompatibility'
            $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage $compatibility.Reason
            return [pscustomobject]$result
        }

        $backupResult = if ($PcPath) {
            $metadata = @{
                sourceSide = 'PC'
                targetSide = 'PC'
                saveSlot = $SlotName
                operationType = 'DaemonSync'
                deviceId = $DeviceId
            }
            New-BridgeBackup -SlotName $SlotName -TargetSide 'PC' -OperationType 'DaemonSync' -SourcePath $PcPath -BackupRoot $Config.backupRoot -Metadata $metadata -DryRun:$DryRun
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
            Invoke-BridgeBackupPrune -SlotName $SlotName -TargetSide 'PC' -BackupRoot $Config.backupRoot -RetentionCount $Config.retentionCount -DryRun:$DryRun | Out-Null
        }

        $pcRoot = Get-WindowsSaveRoot
        $targetPcPath = Join-Path -Path $pcRoot -ChildPath $SlotName
        $effectivePayload = New-EffectiveTransferPayload -Config $Config -Purpose 'daemon-usephone-effective' -SlotName $SlotName -IncomingSlotPath $stagedPhonePath -CurrentTargetSlotPath $PcPath -TargetSide 'PC'
        if (-not $DryRun) {
            Copy-BridgeDirectory -SourcePath $effectivePayload.Path -TargetPath $targetPcPath -CleanTarget | Out-Null
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

        $result.Status = 'Synced'
        $result.Reason = Join-SelectionReason -SelectionMessage $selectionMessage -OutcomeMessage 'Copied the phone save to the PC and verified the result.'
        $result.BackupResult = $backupResult
        $result.PreservedSettings = $effectivePayload
        $result.VerificationResult = $verification
        $result.DetectedPaths['effectivePayload'] = $effectivePayload.Path
        return [pscustomobject]$result
    }
    catch {
        $result.Status = 'Failed'
        $result.Reason = $_.Exception.Message
        return [pscustomobject]$result
    }
}

function Invoke-DaemonSyncCycle {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [switch]$DryRun,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$RunRecord
    )

    try {
        $device = Resolve-SelectedDevice -Config $Config -NonInteractive
    }
    catch {
        $RunRecord.finalOutcome = 'SkippedUnavailable'
        $RunRecord.notes = @($_.Exception.Message)
        return [pscustomobject]@{
            ExitCode = 0
            FinalOutcome = 'SkippedUnavailable'
            Compatibility = @{}
            ComparisonSummary = @{}
            OverwriteTarget = ''
            VerificationResult = @{}
            Errors = @()
            Preferences = @{}
            OutputLines = @("Daemon cycle skipped: $($_.Exception.Message)")
        }
    }

    Set-BridgeRunRecordSelectedDevice -RunRecord $RunRecord -Device $device

    if (Test-StardewRunning) {
        $RunRecord.finalOutcome = 'SkippedPcGameRunning'
        $RunRecord.notes = @('Skipped daemon cycle because Stardew Valley is running on the PC.')
        return [pscustomobject]@{
            ExitCode = 0
            FinalOutcome = 'SkippedPcGameRunning'
            Compatibility = @{}
            ComparisonSummary = @{}
            OverwriteTarget = ''
            VerificationResult = @{}
            Errors = @()
            Preferences = @{}
            OutputLines = @('Daemon cycle skipped because Stardew Valley is running on the PC.')
        }
    }

    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $device.Id
    $pcRoot = Get-WindowsSaveRoot
    $pcSlots = @(Get-LocalSaveSlots -RootPath $pcRoot -Side 'PC')
    $phoneSlots = @(Get-PhoneSaveSlots -Config $Config -DeviceId $device.Id)
    $slotNames = @(Get-AllSaveSlotNames -PcSlots $pcSlots -PhoneSlots $phoneSlots)
    $pcGameVersion = Get-PCGameVersion -Config $Config
    $pcGameVersionMessage = Get-PCGameVersionMessage -PcGameVersion $pcGameVersion
    $phoneGameVersion = Get-PhoneGameVersion -Config $Config -DeviceId $device.Id
    $syncResults = @()

    foreach ($slotName in $slotNames) {
        $pcPath = Get-SlotPathByName -Slots $pcSlots -SlotName $slotName
        $slotResult = @(Invoke-DaemonSlotSync -Config $Config -DeviceId $device.Id -AndroidSaveRoot $androidSaveRoot -SlotName $slotName -PcPath $pcPath -PcGameVersion $pcGameVersion -PhoneGameVersion $phoneGameVersion -DryRun:$DryRun) | Select-Object -Last 1
        $syncResults += $slotResult
    }

    $summary = [ordered]@{
        totalSlots = $slotNames.Count
        synced = @($syncResults | Where-Object { $_.Status -eq 'Synced' }).Count
        alreadySynced = @($syncResults | Where-Object { $_.Status -eq 'AlreadySynced' }).Count
        skipped = @($syncResults | Where-Object { $_.Status -like 'Skipped*' }).Count
        failed = @($syncResults | Where-Object { $_.Status -eq 'Failed' }).Count
    }

    $RunRecord.selectedSaveSlot = 'all-slots'
    $RunRecord.detectedPaths = [ordered]@{
        pcRoot = $pcRoot
        androidRoot = $androidSaveRoot
    }
    $RunRecord.compatibility = [ordered]@{
        pcGameVersion = if ($pcGameVersion.Parsed) { $pcGameVersion.Parsed.ToString() } else { $null }
        phoneGameVersion = if ($phoneGameVersion.Parsed) { $phoneGameVersion.Parsed.ToString() } else { $null }
    }
    $RunRecord.comparisonSummary = $summary
    $RunRecord['syncResults'] = [object[]]@($syncResults)
    $RunRecord.notes = @()
    $RunRecord.finalOutcome = if ($summary.failed -gt 0) { 'CompletedWithIssues' } else { 'Completed' }

    return [pscustomobject]@{
        ExitCode = 0
        FinalOutcome = $RunRecord.finalOutcome
        Compatibility = $RunRecord.compatibility
        ComparisonSummary = $summary
        OverwriteTarget = ''
        VerificationResult = @{}
        Errors = @()
        Preferences = Get-PCGameVersionPreferenceUpdate -PcGameVersion $pcGameVersion
        OutputLines = @(
            (Get-BridgeDeviceSelectionSummaryLine -Device $device)
            $(if (-not [string]::IsNullOrWhiteSpace($RunRecord.cycleDeviceEndpoint)) { "Daemon endpoint: $($RunRecord.cycleDeviceEndpoint)" } else { $null })
            (Get-PCGameVersionSummaryLine -PcGameVersion $pcGameVersion)
            (Get-PhoneGameVersionSummaryLine -PhoneGameVersion $phoneGameVersion)
            $pcGameVersionMessage
        ) + @($syncResults | ForEach-Object { Get-DaemonSlotSummaryLine -SyncResult $_ }) + @(
            "Slots checked: $($summary.totalSlots)"
            "Slots synced: $($summary.synced)"
            "Slots already in sync: $($summary.alreadySynced)"
            "Slots skipped: $($summary.skipped)"
            "Slots failed: $($summary.failed)"
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
}

function Start-BridgeDaemon {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [switch]$DryRun
    )

    $intervalSeconds = Get-DaemonIntervalSeconds -Config $Config

    while ($true) {
        $runRecord = New-BridgeRunRecord -Action 'Daemon' -DryRun:$DryRun -ConfigPath $Config._configPath

        try {
            $result = Invoke-DaemonSyncCycle -Config $Config -RepositoryRoot $RepositoryRoot -DryRun:$DryRun -RunRecord $runRecord
            if ($result.Preferences -and $result.Preferences.Count -gt 0 -and $Config._configPath) {
                Save-BridgePreferences -Config $Config -ConfigPath $Config._configPath -Preferences $result.Preferences
            }
            $runRecord.finalOutcome = $result.FinalOutcome
            $runRecord.compatibility = $result.Compatibility
            $runRecord.comparisonSummary = $result.ComparisonSummary
            $runRecord.overwriteTarget = $result.OverwriteTarget
            $runRecord.verificationResult = $result.VerificationResult
            $runRecord.errors = $result.Errors
            $logPaths = Write-BridgeRunLog -Config $Config -RepositoryRoot $RepositoryRoot -RunRecord $runRecord -PassThru

            if ($result.OutputLines) {
                $result.OutputLines | ForEach-Object { Write-Host $_ }
            }
            if ($logPaths -and -not [string]::IsNullOrWhiteSpace($logPaths.TextPath)) {
                Write-Host ("Cycle log written to {0}" -f $logPaths.TextPath)
            }
            if (Test-ShouldStopDaemonForUnknownPcVersion -Result $result -RunRecord $runRecord) {
                Write-Warning 'Daemon stopped after the first cycle because the PC game version could not be determined for Phone -> PC compatibility checks.'
                return
            }
        }
        catch {
            $runRecord.finalOutcome = 'Failed'
            $runRecord.errors = @($_.Exception.Message)
            Write-BridgeRunLog -Config $Config -RepositoryRoot $RepositoryRoot -RunRecord $runRecord
            Write-Warning $_.Exception.Message
        }

        Wait-BridgeDaemonInterval -Seconds $intervalSeconds
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
        'Daemon' {
            Start-BridgeDaemon -Config $Config -RepositoryRoot $RepositoryRoot -DryRun:$DryRun
            return [pscustomobject]@{
                ExitCode = 0
                FinalOutcome = 'Exited'
                Compatibility = @{}
                ComparisonSummary = @{}
                OverwriteTarget = ''
                VerificationResult = @{}
                Errors = @()
                Preferences = @{}
                OutputLines = @()
            }
        }
        default {
            throw "Unsupported action '$Action'."
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-BridgeAction',
    'Invoke-DaemonSyncCycle'
)
