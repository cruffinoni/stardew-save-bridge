BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Save.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Adb.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Backup.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Workflow.psm1') -Force
    $fixturesRoot = Join-Path -Path $repoRoot -ChildPath 'fixtures'
}

Describe 'Integration flows' {
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
        ($result.OutputLines -join "`n") | Should -Match ('Dry-run: backup would be created at ' + [regex]::Escape((Join-Path -Path $config.backupRoot -ChildPath 'ValidSave_123456789\Phone')))
        $result.OutputLines | Should -Contain 'The current Phone save would be overwritten.'
        $result.OutputLines | Should -Contain 'Verification skipped in dry-run mode.'
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
}
