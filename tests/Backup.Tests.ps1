BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Backup.psm1') -Force
    $sourcePath = Join-Path -Path $repoRoot -ChildPath 'fixtures/ValidSave_123456789'
}

Describe 'Backup management' {
    It 'creates a backup with metadata and content' {
        $backup = New-BridgeBackup `
            -SlotName 'ValidSave_123456789' `
            -TargetSide 'PC' `
            -OperationType 'UsePhoneSave' `
            -SourcePath $sourcePath `
            -BackupRoot $TestDrive `
            -Metadata @{ sourceSide = 'PC'; targetSide = 'PC'; saveSlot = 'ValidSave_123456789'; operationType = 'UsePhoneSave' }

        $backup.Created | Should -BeTrue
        (Test-Path -LiteralPath $backup.MetadataPath) | Should -BeTrue
        @(Get-BridgeBackups -SlotName 'ValidSave_123456789' -BackupRoot $TestDrive).Count | Should -Be 1
    }

    It 'prunes backups past the retention count' {
        1..3 | ForEach-Object {
            $backupRoot = Join-Path -Path $TestDrive -ChildPath ('run-' + $_)
            New-BridgeBackup `
                -SlotName 'ValidSave_123456789' `
                -TargetSide 'Phone' `
                -OperationType 'UsePCSave' `
                -SourcePath $sourcePath `
                -BackupRoot $TestDrive `
                -Metadata @{ sequence = $_ } | Out-Null
            Start-Sleep -Milliseconds 20
        }

        $removed = Invoke-BridgeBackupPrune -SlotName 'ValidSave_123456789' -TargetSide 'Phone' -BackupRoot $TestDrive -RetentionCount 2
        $removed.Count | Should -Be 1
        (@(Get-BridgeBackups -SlotName 'ValidSave_123456789' -BackupRoot $TestDrive | Where-Object { $_.TargetSide -eq 'Phone' })).Count | Should -Be 2
    }
}
