BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Save.psm1') -Force
    $fixturesRoot = Join-Path -Path $repoRoot -ChildPath 'fixtures'
}

Describe 'Save validation and comparison' {
    It 'discovers multiple save slots from a save root' {
        $slots = Get-LocalSaveSlots -RootPath (Join-Path -Path $fixturesRoot -ChildPath 'MultipleSlots') -Side 'PC'

        $slots.Name | Should -Contain 'SlotA_111'
        $slots.Name | Should -Contain 'SlotB_222'
    }

    It 'validates a complete save fixture' {
        $result = Test-SaveFolder -FolderPath (Join-Path -Path $fixturesRoot -ChildPath 'ValidSave_123456789')

        $result.IsValid | Should -BeTrue
        $result.HasOldFiles | Should -BeFalse
        $result.SaveVersion.Parsed.ToString() | Should -Be '1.6.15'
    }

    It 'detects a missing SaveGameInfo file' {
        $result = Test-SaveFolder -FolderPath (Join-Path -Path $fixturesRoot -ChildPath 'MissingSaveGameInfo_123456789')

        $result.IsValid | Should -BeFalse
        $result.MissingFiles | Should -Contain 'SaveGameInfo'
    }

    It 'detects _old files when present' {
        $result = Test-SaveFolder -FolderPath (Join-Path -Path $fixturesRoot -ChildPath 'ValidSaveWithOld_123456789')

        $result.HasOldFiles | Should -BeTrue
        $result.OldFiles | Should -Contain 'ValidSaveWithOld_123456789_old'
    }

    It 'classifies changed files correctly' {
        $comparison = Compare-SaveFolders `
            -PCPath (Join-Path -Path $fixturesRoot -ChildPath 'MismatchedPc_123456789') `
            -PhonePath (Join-Path -Path $fixturesRoot -ChildPath 'MismatchedPhone_123456789')

        $comparison.OverallStatus | Should -Be 'Different'
        $comparison.Summary.contentDiffers | Should -BeGreaterThan 0
    }

    It 'allows older saves on newer games and blocks newer saves on older games' {
        $newerSave = (Test-SaveFolder -FolderPath (Join-Path -Path $fixturesRoot -ChildPath 'NewerSave_123456789')).SaveVersion.Parsed
        $olderSave = (Test-SaveFolder -FolderPath (Join-Path -Path $fixturesRoot -ChildPath 'OlderSave_123456789')).SaveVersion.Parsed

        (Test-VersionCompatibility -SaveVersion $olderSave -TargetGameVersion ([version]'1.6.15')).Status | Should -Be 'Safe'
        (Test-VersionCompatibility -SaveVersion $newerSave -TargetGameVersion ([version]'1.5.6')).Status | Should -Be 'Blocked'
    }

    It 'reports unknown compatibility when a version cannot be determined' {
        $result = Test-VersionCompatibility -SaveVersion $null -TargetGameVersion ([version]'1.6.15')

        $result.Status | Should -Be 'Unknown'
    }
}
