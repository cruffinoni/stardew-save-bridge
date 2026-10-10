BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Save.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Adb.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Backup.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Workflow.psm1') -Force
    $fixturesRoot = Join-Path -Path $repoRoot -ChildPath 'fixtures'

    function New-TestSaveSlot {
        param(
            [Parameter(Mandatory)]
            [string]$RootPath,

            [Parameter(Mandatory)]
            [string]$SlotName,

            [Parameter(Mandatory)]
            [string]$PlayerName,

            [Parameter(Mandatory)]
            [int]$Money,

            [Parameter(Mandatory)]
            [string]$UiScale,

            [Parameter(Mandatory)]
            [string]$ZoomLevel,

            [Parameter(Mandatory)]
            [string]$MoveUpButton,

            [Parameter(Mandatory)]
            [string]$ToolKey,

            [Parameter(Mandatory)]
            [string]$WindowMode
        )

        $slotPath = Join-Path -Path $RootPath -ChildPath $SlotName
        New-Item -ItemType Directory -Path $slotPath -Force | Out-Null

        @"
<?xml version="1.0" encoding="utf-8"?>
<SaveGame>
  <player>
    <name>$PlayerName</name>
  </player>
  <gameVersion>1.6.15</gameVersion>
  <money>$Money</money>
  <options>
    <uiScale>$UiScale</uiScale>
    <zoomLevel>$ZoomLevel</zoomLevel>
    <moveUpButton>$MoveUpButton</moveUpButton>
    <useToolKey>$ToolKey</useToolKey>
    <windowMode>$WindowMode</windowMode>
  </options>
</SaveGame>
"@ | Set-Content -LiteralPath (Join-Path -Path $slotPath -ChildPath $SlotName) -Encoding UTF8

        @"
<?xml version="1.0" encoding="utf-8"?>
<Farmer>
  <name>$PlayerName</name>
</Farmer>
"@ | Set-Content -LiteralPath (Join-Path -Path $slotPath -ChildPath 'SaveGameInfo') -Encoding UTF8

        return $slotPath
    }

    function Set-TestSaveSlotTimestamp {
        param(
            [Parameter(Mandatory)]
            [string]$SlotPath,

            [Parameter(Mandatory)]
            [datetime]$Timestamp
        )

        Get-ChildItem -LiteralPath $SlotPath -Recurse -File | ForEach-Object {
            $_.LastWriteTimeUtc = $Timestamp
        }
    }
}

Describe 'Integration flows' {
    BeforeEach {
        Mock Get-AdbMdnsDeviceList { @() } -ModuleName StardewSaveBridge.Workflow
    }

    It 'compares local fixtures and produces a recommendation signal' {
        $comparison = Compare-SaveFolders `
            -PCPath (Join-Path -Path $fixturesRoot -ChildPath 'ValidSave_123456789') `
            -PhonePath (Join-Path -Path $fixturesRoot -ChildPath 'MismatchedPhone_123456789')

        $comparison.OverallStatus | Should -Be 'Different'
        $comparison.NewerSideHint.Hint | Should -Match 'PC|Phone|SameTimestamp'
    }

    It 'creates and prunes local backups without adb' {
        $first = New-BridgeBackup `
            -SlotName 'ValidSave_123456789' `
            -TargetSide 'PC' `
            -OperationType 'RestoreBackup' `
            -SourcePath (Join-Path -Path $fixturesRoot -ChildPath 'ValidSave_123456789') `
            -BackupRoot $TestDrive `
            -Metadata @{ sourceSide = 'PC'; targetSide = 'PC'; saveSlot = 'ValidSave_123456789'; operationType = 'RestoreBackup' }

        Start-Sleep -Milliseconds 20

        $second = New-BridgeBackup `
            -SlotName 'ValidSave_123456789' `
            -TargetSide 'PC' `
            -OperationType 'RestoreBackup' `
            -SourcePath (Join-Path -Path $fixturesRoot -ChildPath 'OlderSave_123456789') `
            -BackupRoot $TestDrive `
            -Metadata @{ sourceSide = 'PC'; targetSide = 'PC'; saveSlot = 'ValidSave_123456789'; operationType = 'RestoreBackup' }

        $removed = Invoke-BridgeBackupPrune -SlotName 'ValidSave_123456789' -TargetSide 'PC' -BackupRoot $TestDrive -RetentionCount 1

        $first.Created | Should -BeTrue
        $second.Created | Should -BeTrue
        $removed.Count | Should -Be 1
    }

    It 'supports dry-run handoff with mocked adb dependencies' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePC' -DryRun -Force -ConfigPath $config._configPath

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @([pscustomobject]@{ Name = 'ValidSave_123456789'; Path = '/phone/ValidSave_123456789'; Side = 'Phone' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            Copy-Item -LiteralPath (Join-Path -Path $fixturesRoot -ChildPath 'ValidSave_123456789') -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $fixturesRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePC' -SaveSlot 'ValidSave_123456789' -DeviceId 'device-1' -DryRun -Force -NonInteractive -RunRecord $runRecord

        $result.FinalOutcome | Should -Be 'DryRunCompleted'
        $result.OverwriteTarget | Should -Be 'Phone'
        $result.OutputLines | Should -Contain 'Selected device: device-1 via USB fallback'
        $result.OutputLines | Should -Contain 'Detected Phone game version: 1.6.15'
        ($result.OutputLines -join "`n") | Should -Match ('Dry-run: backup would be created at ' + [regex]::Escape((Join-Path -Path $config.backupRoot -ChildPath 'ValidSave_123456789\Phone')))
        $result.OutputLines | Should -Contain 'The current Phone save would be overwritten.'
        $result.OutputLines | Should -Contain 'Verification skipped in dry-run mode.'
    }

    It 'uses an mdns-discovered device and surfaces it in the output' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'Inspect' -ConfigPath $config._configPath

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbMdnsDeviceList {
            @([pscustomobject]@{
                Id = '192.168.1.4:39101'
                State = 'device'
                DiscoverySource = 'mDNS'
                ServiceName = 'adb-Secure._adb-tls-connect._tcp'
                ServiceType = '_adb-tls-connect._tcp'
                Address = '192.168.1.4'
                Port = 39101
                DisplayName = 'adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101)'
                SelectionReason = ''
            })
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @() } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @() } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $fixturesRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PCGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'Inspect' -SaveSlot 'ValidSave_123456789' -NonInteractive -RunRecord $runRecord

        $result.OutputLines | Should -Contain 'Selected device: adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101) via mDNS (auto-selected)'
        $runRecord.deviceSelection.source | Should -Be 'mDNS'
    }

    It 'surfaces auto-detected PC version details during inspect and returns a config preference update' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'Inspect' -ConfigPath $config._configPath
        $detectedPath = 'C:\Games\Stardew Valley\Stardew Valley.exe'

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @() } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $fixturesRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PCGameVersion {
            [pscustomobject]@{
                Raw = '1.6.15'
                Parsed = [version]'1.6.15'
                Source = $detectedPath
                Detection = 'AutoDetected'
                ResolvedPath = $detectedPath
                ShouldPersist = $true
                Message = "PC game executable auto-detected at '$detectedPath'. Saved to config/user.json."
            }
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'Inspect' -SaveSlot 'ValidSave_123456789' -DeviceId 'device-1' -NonInteractive -RunRecord $runRecord

        $result.OutputLines | Should -Contain 'Detected Phone game version: 1.6.15'
        $result.OutputLines | Should -Contain 'Detected PC game version: 1.6.15'
        $result.OutputLines | Should -Contain "PC game executable auto-detected at '$detectedPath'. Saved to config/user.json."
        $result.Preferences.pcGameExePath | Should -Be $detectedPath
    }

    It 'explains dry-run handoff when the destination save does not exist' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePC' -DryRun -Force -ConfigPath $config._configPath

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @() } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $fixturesRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePC' -SaveSlot 'ValidSave_123456789' -DeviceId 'device-1' -DryRun -Force -NonInteractive -RunRecord $runRecord

        $result.OutputLines | Should -Contain 'No existing phone save was found, so no backup was needed.'
        $result.OutputLines | Should -Contain 'This action would create the save on the phone.'
        $result.OutputLines | Should -Contain 'Verification skipped in dry-run mode.'
    }

    It 'uses the latest PC save when UsePC runs without a slot in non-interactive mode' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePC' -DryRun -Force -ConfigPath $config._configPath
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'pc-saves'
        $olderSlotName = 'OlderFarm_111'
        $latestSlotName = 'LatestFarm_222'

        $olderSlotPath = New-TestSaveSlot -RootPath $pcRoot -SlotName $olderSlotName -PlayerName 'Older Farmer' -Money 100 -UiScale '0.80' -ZoomLevel '1.05' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed'
        $latestSlotPath = New-TestSaveSlot -RootPath $pcRoot -SlotName $latestSlotName -PlayerName 'Latest Farmer' -Money 250 -UiScale '0.85' -ZoomLevel '1.10' -MoveUpButton 'Up' -ToolKey 'MouseRight' -WindowMode 'Borderless'
        Set-TestSaveSlotTimestamp -SlotPath $olderSlotPath -Timestamp (Get-Date '2026-03-14T08:00:00Z')
        Set-TestSaveSlotTimestamp -SlotPath $latestSlotPath -Timestamp (Get-Date '2026-03-14T12:00:00Z')

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @() } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePC' -DeviceId 'device-1' -DryRun -Force -NonInteractive -RunRecord $runRecord

        $result.FinalOutcome | Should -Be 'DryRunCompleted'
        $runRecord.selectedSaveSlot | Should -Be $latestSlotName
        $result.OutputLines | Should -Contain "Selected save slot: $latestSlotName"
        $result.OutputLines | Should -Contain 'This action would create the save on the phone.'
    }

    It 'pulls the phone copy for the latest PC save when UsePC runs without a slot in non-interactive mode' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePC' -DryRun -Force -ConfigPath $config._configPath
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'pc-saves'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'phone-saves'
        $olderSlotName = 'OlderFarm_333'
        $latestSlotName = 'LatestFarm_444'

        $olderSlotPath = New-TestSaveSlot -RootPath $pcRoot -SlotName $olderSlotName -PlayerName 'Older Farmer' -Money 150 -UiScale '0.80' -ZoomLevel '1.05' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed'
        $latestSlotPath = New-TestSaveSlot -RootPath $pcRoot -SlotName $latestSlotName -PlayerName 'Latest Farmer' -Money 275 -UiScale '0.85' -ZoomLevel '1.10' -MoveUpButton 'Up' -ToolKey 'MouseRight' -WindowMode 'Borderless'
        New-TestSaveSlot -RootPath $phoneRoot -SlotName $latestSlotName -PlayerName 'Phone Farmer' -Money 90 -UiScale '1.40' -ZoomLevel '1.35' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen' | Out-Null
        Set-TestSaveSlotTimestamp -SlotPath $olderSlotPath -Timestamp (Get-Date '2026-03-14T07:00:00Z')
        Set-TestSaveSlotTimestamp -SlotPath $latestSlotPath -Timestamp (Get-Date '2026-03-14T13:00:00Z')

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots {
            @(
                [pscustomobject]@{ Name = $olderSlotName; Path = '/phone/OlderFarm_333'; Side = 'Phone' },
                [pscustomobject]@{ Name = $latestSlotName; Path = '/phone/LatestFarm_444'; Side = 'Phone' }
            )
        } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            $SlotName | Should -Be $latestSlotName
            Copy-Item -LiteralPath (Join-Path -Path $phoneRoot -ChildPath $SlotName) -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePC' -DeviceId 'device-1' -DryRun -Force -NonInteractive -RunRecord $runRecord

        $result.FinalOutcome | Should -Be 'DryRunCompleted'
        $runRecord.selectedSaveSlot | Should -Be $latestSlotName
        Should -Invoke Copy-PhoneSaveToLocal -ModuleName StardewSaveBridge.Workflow -Times 1 -Exactly
        $result.OutputLines | Should -Contain "Selected save slot: $latestSlotName"
        $result.OutputLines | Should -Contain 'The current Phone save would be overwritten.'
    }

    It 'preserves existing PC settings when copying a phone save to the PC' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePhone' -Force -ConfigPath $config._configPath
        $slotName = 'BridgeFarm_777'
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'pc-saves'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'phone-saves'
        $appDataRoot = Join-Path -Path $TestDrive -ChildPath 'appdata'
        $startupPreferencesPath = Join-Path -Path $appDataRoot -ChildPath 'StardewValley/startup_preferences'

        New-TestSaveSlot -RootPath $pcRoot -SlotName $slotName -PlayerName 'PC Farmer' -Money 100 -UiScale '0.80' -ZoomLevel '1.05' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed' | Out-Null
        New-TestSaveSlot -RootPath $phoneRoot -SlotName $slotName -PlayerName 'Phone Farmer' -Money 999 -UiScale '1.40' -ZoomLevel '1.35' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen' | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Path $startupPreferencesPath -Parent) -Force | Out-Null
        'pc-controls-stay-local' | Set-Content -LiteralPath $startupPreferencesPath -Encoding UTF8

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @([pscustomobject]@{ Name = $slotName; Path = '/phone/BridgeFarm_777'; Side = 'Phone' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            Copy-Item -LiteralPath (Join-Path -Path $phoneRoot -ChildPath $SlotName) -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PCGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $previousAppData = $env:APPDATA
        try {
            $env:APPDATA = $appDataRoot
            $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePhone' -SaveSlot $slotName -DeviceId 'device-1' -Force -NonInteractive -RunRecord $runRecord
        }
        finally {
            $env:APPDATA = $previousAppData
        }

        [xml]$updated = Get-Content -LiteralPath (Join-Path -Path $pcRoot -ChildPath (Join-Path -Path $slotName -ChildPath $slotName)) -Raw

        $result.FinalOutcome | Should -Be 'Completed'
        $result.OutputLines | Should -Contain 'Preserved existing PC settings while replacing the save.'
        $result.OutputLines | Should -Contain 'Detected PC game version: 1.6.15'
        $runRecord.preservedSettings.Applied | Should -BeTrue
        $runRecord.detectedPaths.effectivePayload | Should -Not -BeNullOrEmpty
        $updated.SaveGame.money | Should -Be '999'
        $updated.SaveGame.player.name | Should -Be 'Phone Farmer'
        $updated.SaveGame.options.uiScale | Should -Be '0.80'
        $updated.SaveGame.options.zoomLevel | Should -Be '1.05'
        $updated.SaveGame.options.moveUpButton | Should -Be 'W'
        $updated.SaveGame.options.useToolKey | Should -Be 'MouseLeft'
        $updated.SaveGame.options.windowMode | Should -Be 'Windowed'
        ((Get-Content -LiteralPath $startupPreferencesPath -Raw).Trim()) | Should -Be 'pc-controls-stay-local'
    }

    It 'fails UsePhone with a specific setup message when PC game version cannot be determined' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePhone' -ConfigPath $config._configPath
        $slotName = 'BridgeFarm_777'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'phone-saves'
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'pc-saves'
        $message = 'PC game version could not be determined. Set config/user.json -> pcGameExePath to your Stardew Valley executable, or install Stardew Valley in a supported Steam/GOG location.'

        New-TestSaveSlot -RootPath $phoneRoot -SlotName $slotName -PlayerName 'Phone Farmer' -Money 999 -UiScale '1.40' -ZoomLevel '1.35' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen' | Out-Null
        New-TestSaveSlot -RootPath $pcRoot -SlotName $slotName -PlayerName 'PC Farmer' -Money 100 -UiScale '0.80' -ZoomLevel '1.05' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed' | Out-Null

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @([pscustomobject]@{ Name = $slotName; Path = '/phone/BridgeFarm_777'; Side = 'Phone' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            Copy-Item -LiteralPath (Join-Path -Path $phoneRoot -ChildPath $SlotName) -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PCGameVersion {
            [pscustomobject]@{
                Raw = $null
                Parsed = $null
                Source = 'NotConfigured'
                Detection = 'NotConfigured'
                ResolvedPath = $null
                ShouldPersist = $false
                Message = $message
            }
        } -ModuleName StardewSaveBridge.Workflow

        { Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePhone' -SaveSlot $slotName -DeviceId 'device-1' -NonInteractive -RunRecord $runRecord } | Should -Throw $message
    }

    It 'preserves existing phone settings when copying a PC save to the phone' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $runRecord = New-BridgeRunRecord -Action 'UsePC' -Force -ConfigPath $config._configPath
        $slotName = 'BridgeFarm_888'
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'pc-saves'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'phone-device'

        New-TestSaveSlot -RootPath $pcRoot -SlotName $slotName -PlayerName 'PC Farmer' -Money 777 -UiScale '0.75' -ZoomLevel '1.00' -MoveUpButton 'ArrowUp' -ToolKey 'MouseRight' -WindowMode 'Borderless' | Out-Null
        New-TestSaveSlot -RootPath $phoneRoot -SlotName $slotName -PlayerName 'Phone Farmer' -Money 120 -UiScale '1.55' -ZoomLevel '1.40' -MoveUpButton 'SwipeUp' -ToolKey 'TapTool' -WindowMode 'Fullscreen' | Out-Null

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @([pscustomobject]@{ Name = $slotName; Path = '/phone/BridgeFarm_888'; Side = 'Phone' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            Copy-Item -LiteralPath (Join-Path -Path $phoneRoot -ChildPath $SlotName) -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-LocalSaveToPhone {
            param($Config, $DeviceId, $LocalSlotPath)
            $destination = Join-Path -Path $phoneRoot -ChildPath (Split-Path -Path $LocalSlotPath -Leaf)
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Recurse -Force
            }
            Copy-Item -LiteralPath $LocalSlotPath -Destination $destination -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'UsePC' -SaveSlot $slotName -DeviceId 'device-1' -Force -NonInteractive -RunRecord $runRecord
        [xml]$updated = Get-Content -LiteralPath (Join-Path -Path $phoneRoot -ChildPath (Join-Path -Path $slotName -ChildPath $slotName)) -Raw

        $result.FinalOutcome | Should -Be 'Completed'
        $result.OutputLines | Should -Contain 'Preserved existing Phone settings while replacing the save.'
        $runRecord.preservedSettings.Applied | Should -BeTrue
        $updated.SaveGame.money | Should -Be '777'
        $updated.SaveGame.player.name | Should -Be 'PC Farmer'
        $updated.SaveGame.options.uiScale | Should -Be '1.55'
        $updated.SaveGame.options.zoomLevel | Should -Be '1.40'
        $updated.SaveGame.options.moveUpButton | Should -Be 'SwipeUp'
        $updated.SaveGame.options.useToolKey | Should -Be 'TapTool'
        $updated.SaveGame.options.windowMode | Should -Be 'Fullscreen'
    }

    It 'preserves existing PC settings when restoring a backup to the PC' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $runRecord = New-BridgeRunRecord -Action 'RestoreBackup' -Force -ConfigPath $config._configPath
        $slotName = 'BridgeFarm_999'
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'pc-saves'
        $backupSourceRoot = Join-Path -Path $TestDrive -ChildPath 'backup-source'

        New-TestSaveSlot -RootPath $pcRoot -SlotName $slotName -PlayerName 'Current PC' -Money 250 -UiScale '0.90' -ZoomLevel '1.00' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed' | Out-Null
        $backupSourcePath = New-TestSaveSlot -RootPath $backupSourceRoot -SlotName $slotName -PlayerName 'Backup Farmer' -Money 1400 -UiScale '1.45' -ZoomLevel '1.30' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen'
        $backup = New-BridgeBackup -SlotName $slotName -TargetSide 'Phone' -OperationType 'UsePCSave' -SourcePath $backupSourcePath -BackupRoot $config.backupRoot -Metadata @{ sourceSide = 'Phone'; targetSide = 'Phone'; saveSlot = $slotName; operationType = 'UsePCSave' }

        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'RestoreBackup' -SaveSlot $slotName -BackupId $backup.Id -RestoreTarget 'PC' -Force -NonInteractive -RunRecord $runRecord
        [xml]$updated = Get-Content -LiteralPath (Join-Path -Path $pcRoot -ChildPath (Join-Path -Path $slotName -ChildPath $slotName)) -Raw

        $result.FinalOutcome | Should -Be 'Completed'
        $result.OutputLines | Should -Contain 'Preserved existing PC settings while replacing the save.'
        $updated.SaveGame.money | Should -Be '1400'
        $updated.SaveGame.player.name | Should -Be 'Backup Farmer'
        $updated.SaveGame.options.uiScale | Should -Be '0.90'
        $updated.SaveGame.options.zoomLevel | Should -Be '1.00'
        $updated.SaveGame.options.moveUpButton | Should -Be 'W'
        $updated.SaveGame.options.useToolKey | Should -Be 'MouseLeft'
        $updated.SaveGame.options.windowMode | Should -Be 'Windowed'
    }

    It 'preserves existing phone settings when restoring a backup to the phone' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $runRecord = New-BridgeRunRecord -Action 'RestoreBackup' -Force -ConfigPath $config._configPath
        $slotName = 'BridgeFarm_1000'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'phone-device'
        $backupSourceRoot = Join-Path -Path $TestDrive -ChildPath 'backup-source'

        New-TestSaveSlot -RootPath $phoneRoot -SlotName $slotName -PlayerName 'Current Phone' -Money 220 -UiScale '1.65' -ZoomLevel '1.45' -MoveUpButton 'SwipeUp' -ToolKey 'TapTool' -WindowMode 'Fullscreen' | Out-Null
        $backupSourcePath = New-TestSaveSlot -RootPath $backupSourceRoot -SlotName $slotName -PlayerName 'Backup Farmer' -Money 1600 -UiScale '0.70' -ZoomLevel '0.95' -MoveUpButton 'ArrowUp' -ToolKey 'MouseRight' -WindowMode 'Windowed'
        $backup = New-BridgeBackup -SlotName $slotName -TargetSide 'PC' -OperationType 'UsePhoneSave' -SourcePath $backupSourcePath -BackupRoot $config.backupRoot -Metadata @{ sourceSide = 'PC'; targetSide = 'PC'; saveSlot = $slotName; operationType = 'UsePhoneSave' }

        Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
        Mock Get-AdbDeviceList { @([pscustomobject]@{ Id = 'device-1'; State = 'device' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots { @([pscustomobject]@{ Name = $slotName; Path = '/phone/BridgeFarm_1000'; Side = 'Phone' }) } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            Copy-Item -LiteralPath (Join-Path -Path $phoneRoot -ChildPath $SlotName) -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-LocalSaveToPhone {
            param($Config, $DeviceId, $LocalSlotPath)
            $destination = Join-Path -Path $phoneRoot -ChildPath (Split-Path -Path $LocalSlotPath -Leaf)
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Recurse -Force
            }
            Copy-Item -LiteralPath $LocalSlotPath -Destination $destination -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-BridgeAction -Config $config -RepositoryRoot $repoRoot -Action 'RestoreBackup' -SaveSlot $slotName -BackupId $backup.Id -RestoreTarget 'Phone' -DeviceId 'device-1' -Force -NonInteractive -RunRecord $runRecord
        [xml]$updated = Get-Content -LiteralPath (Join-Path -Path $phoneRoot -ChildPath (Join-Path -Path $slotName -ChildPath $slotName)) -Raw

        $result.FinalOutcome | Should -Be 'Completed'
        $result.OutputLines | Should -Contain 'Preserved existing Phone settings while replacing the save.'
        $updated.SaveGame.money | Should -Be '1600'
        $updated.SaveGame.player.name | Should -Be 'Backup Farmer'
        $updated.SaveGame.options.uiScale | Should -Be '1.65'
        $updated.SaveGame.options.zoomLevel | Should -Be '1.45'
        $updated.SaveGame.options.moveUpButton | Should -Be 'SwipeUp'
        $updated.SaveGame.options.useToolKey | Should -Be 'TapTool'
        $updated.SaveGame.options.windowMode | Should -Be 'Fullscreen'
    }

    It 'syncs all slots during a daemon cycle with mdns-selected discovery' {
        $config = Initialize-BridgeConfig -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'config/user.json') -RepositoryRoot $repoRoot
        $config.backupRoot = Join-Path -Path $TestDrive -ChildPath 'backups'
        $config.stagingDirectory = Join-Path -Path $TestDrive -ChildPath 'staging'
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $config.pcGameExePath = ''
        $config.wirelessDeviceHost = '192.168.1.4'
        $config.wirelessDevicePort = 39101
        $runRecord = New-BridgeRunRecord -Action 'Daemon' -ConfigPath $config._configPath
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'daemon-pc-saves'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'daemon-phone-saves'

        $pcSlotPath = New-TestSaveSlot -RootPath $pcRoot -SlotName 'DaemonFarm_1' -PlayerName 'PC Farmer' -Money 900 -UiScale '0.80' -ZoomLevel '1.05' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed'
        $phoneSlotPath = New-TestSaveSlot -RootPath $phoneRoot -SlotName 'DaemonFarm_1' -PlayerName 'Phone Farmer' -Money 150 -UiScale '1.40' -ZoomLevel '1.35' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen'
        New-TestSaveSlot -RootPath $phoneRoot -SlotName 'DaemonFarm_2' -PlayerName 'Phone Only' -Money 500 -UiScale '1.20' -ZoomLevel '1.15' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen' | Out-Null
        Set-TestSaveSlotTimestamp -SlotPath $phoneSlotPath -Timestamp (Get-Date '2026-03-14T08:00:00Z')
        Set-TestSaveSlotTimestamp -SlotPath $pcSlotPath -Timestamp (Get-Date '2026-03-14T12:00:00Z')

        Mock Resolve-SelectedDevice {
            [pscustomobject]@{
                Id = '192.168.1.4:39101'
                State = 'device'
                DiscoverySource = 'mDNS'
                ServiceName = 'adb-Secure._adb-tls-connect._tcp'
                ServiceType = '_adb-tls-connect._tcp'
                Address = '192.168.1.4'
                Port = 39101
                DisplayName = 'adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101)'
                SelectionReason = 'AutoSelectedMdns'
            }
        } -ModuleName StardewSaveBridge.Workflow
        Mock Test-StardewRunning { $false } -ModuleName StardewSaveBridge.Workflow
        Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Workflow
        Mock Get-WindowsSaveRoot { $pcRoot } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneSaveSlots {
            @(Get-ChildItem -LiteralPath $phoneRoot -Directory | Sort-Object -Property Name | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Path = '/phone/' + $_.Name
                    Side = 'Phone'
                }
            })
        } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-PhoneSaveToLocal {
            param($Config, $DeviceId, $SlotName, $TargetPath)
            Copy-Item -LiteralPath (Join-Path -Path $phoneRoot -ChildPath $SlotName) -Destination $TargetPath -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Copy-LocalSaveToPhone {
            param($Config, $DeviceId, $LocalSlotPath)
            $destination = Join-Path -Path $phoneRoot -ChildPath (Split-Path -Path $LocalSlotPath -Leaf)
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Recurse -Force
            }
            Copy-Item -LiteralPath $LocalSlotPath -Destination $destination -Recurse -Force
        } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PCGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow
        Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow

        $result = Invoke-DaemonSyncCycle -Config $config -RepositoryRoot $repoRoot -RunRecord $runRecord
        [xml]$updatedPhone = Get-Content -LiteralPath (Join-Path -Path $phoneRoot -ChildPath 'DaemonFarm_1/DaemonFarm_1') -Raw
        [xml]$createdPc = Get-Content -LiteralPath (Join-Path -Path $pcRoot -ChildPath 'DaemonFarm_2/DaemonFarm_2') -Raw

        $result.FinalOutcome | Should -Be 'Completed'
        $result.OutputLines | Should -Contain 'Selected device: adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101) via mDNS (auto-selected)'
        ($result.OutputLines | Where-Object { $_ -like 'Slot DaemonFarm_1:*' } | Select-Object -First 1) | Should -Be 'Slot DaemonFarm_1: Synced PC -> Phone - Selected the PC save because its latest file timestamp is newer (PC: 2026-03-14T12:00:00.0000000Z; Phone: 2026-03-14T08:00:00.0000000Z). Copied the PC save to the phone and verified the result.'
        ($result.OutputLines | Where-Object { $_ -like 'Slot DaemonFarm_2:*' } | Select-Object -First 1) | Should -Be 'Slot DaemonFarm_2: Synced Phone -> PC - Selected the phone save because no PC save exists for this slot. Copied the phone save to the PC and verified the result.'
        $result.OutputLines | Should -Contain 'Slots synced: 2'
        $updatedPhone.SaveGame.money | Should -Be '900'
        $updatedPhone.SaveGame.player.name | Should -Be 'PC Farmer'
        $updatedPhone.SaveGame.options.uiScale | Should -Be '1.40'
        $createdPc.SaveGame.money | Should -Be '500'
        $createdPc.SaveGame.player.name | Should -Be 'Phone Only'
    }

    It 'uses the preserved phone timestamp when comparing a staged phone copy' {
        $pcRoot = Join-Path -Path $TestDrive -ChildPath 'compare-preserve-pc'
        $phoneRoot = Join-Path -Path $TestDrive -ChildPath 'compare-preserve-phone'
        $stagingRoot = Join-Path -Path $TestDrive -ChildPath 'compare-preserve-staging'
        $slotName = 'TimestampFarm_1'
        $pcSlotPath = New-TestSaveSlot -RootPath $pcRoot -SlotName $slotName -PlayerName 'PC Farmer' -Money 900 -UiScale '0.80' -ZoomLevel '1.05' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed'
        $phoneSlotPath = New-TestSaveSlot -RootPath $phoneRoot -SlotName $slotName -PlayerName 'Phone Farmer' -Money 150 -UiScale '1.40' -ZoomLevel '1.35' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen'
        $stagedPhonePath = Join-Path -Path $stagingRoot -ChildPath $slotName
        $phoneTimestamp = Get-Date '2026-03-14T08:00:00Z'
        $pcTimestamp = Get-Date '2026-03-14T12:00:00Z'

        Set-TestSaveSlotTimestamp -SlotPath $phoneSlotPath -Timestamp $phoneTimestamp
        Set-TestSaveSlotTimestamp -SlotPath $pcSlotPath -Timestamp $pcTimestamp
        Copy-Item -LiteralPath $phoneSlotPath -Destination $stagedPhonePath -Recurse -Force
        Set-TestSaveSlotTimestamp -SlotPath $stagedPhonePath -Timestamp $phoneTimestamp

        $comparison = Compare-SaveFolders -PCPath $pcSlotPath -PhonePath $stagedPhonePath
        $stagedLatest = Get-ChildItem -LiteralPath $stagedPhonePath -Recurse -File | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1

        $comparison.NewerSideHint.Hint | Should -Be 'PC'
        $comparison.NewerSideHint.Message | Should -Be 'Selected the PC save because its latest file timestamp is newer (PC: 2026-03-14T12:00:00.0000000Z; Phone: 2026-03-14T08:00:00.0000000Z).'
        $stagedLatest.LastWriteTimeUtc | Should -Be $phoneTimestamp.ToUniversalTime()
    }
}
