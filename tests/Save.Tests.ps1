BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Save.psm1') -Force
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

    It 'preserves settings-shaped nodes without changing gameplay data' {
        $referencePath = New-TestSaveSlot `
            -RootPath $TestDrive `
            -SlotName 'Reference_111' `
            -PlayerName 'Reference' `
            -Money 120 `
            -UiScale '0.85' `
            -ZoomLevel '1.10' `
            -MoveUpButton 'W' `
            -ToolKey 'MouseLeft' `
            -WindowMode 'Windowed'

        $targetPath = New-TestSaveSlot `
            -RootPath $TestDrive `
            -SlotName 'Target_222' `
            -PlayerName 'Incoming' `
            -Money 999 `
            -UiScale '1.50' `
            -ZoomLevel '1.35' `
            -MoveUpButton 'Tap' `
            -ToolKey 'GamepadX' `
            -WindowMode 'Fullscreen'

        $result = Sync-SaveSettingsFromReference -ReferenceFolderPath $referencePath -TargetFolderPath $targetPath
        [xml]$updated = Get-Content -LiteralPath (Join-Path -Path $targetPath -ChildPath 'Target_222') -Raw

        $result.Applied | Should -BeTrue
        $updated.SaveGame.money | Should -Be '999'
        $updated.SaveGame.player.name | Should -Be 'Incoming'
        $updated.SaveGame.options.uiScale | Should -Be '0.85'
        $updated.SaveGame.options.zoomLevel | Should -Be '1.10'
        $updated.SaveGame.options.moveUpButton | Should -Be 'W'
        $updated.SaveGame.options.useToolKey | Should -Be 'MouseLeft'
        $updated.SaveGame.options.windowMode | Should -Be 'Windowed'
    }
}
