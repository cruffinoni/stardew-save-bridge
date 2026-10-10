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

    function Get-TestExecutablePath {
        $candidates = @(
            (Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'),
            (Join-Path -Path $PSHOME -ChildPath 'powershell.exe'),
            $(if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) { Join-Path -Path $env:WINDIR -ChildPath 'System32/notepad.exe' } else { $null })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }

        if ($candidates.Count -eq 0) {
            throw 'No Windows executable with version metadata is available for testing.'
        }

        return $candidates[0]
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

    It 'returns a newer-side hint message when the PC timestamp is newer' {
        $pcPath = New-TestSaveSlot -RootPath $TestDrive -SlotName 'HintFarm_1' -PlayerName 'PC Farmer' -Money 100 -UiScale '0.80' -ZoomLevel '1.00' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed'
        $phonePath = New-TestSaveSlot -RootPath $TestDrive -SlotName 'HintFarm_2' -PlayerName 'Phone Farmer' -Money 100 -UiScale '1.20' -ZoomLevel '1.10' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen'
        Set-TestSaveSlotTimestamp -SlotPath $phonePath -Timestamp (Get-Date '2026-03-14T08:00:00Z')
        Set-TestSaveSlotTimestamp -SlotPath $pcPath -Timestamp (Get-Date '2026-03-14T12:00:00Z')

        $result = & (Get-Module StardewSaveBridge.Save) {
            param($innerPcPath, $innerPhonePath)
            Get-NewerSideHint -PCPath $innerPcPath -PhonePath $innerPhonePath
        } $pcPath $phonePath

        $result.Hint | Should -Be 'PC'
        $result.ReasonCode | Should -Be 'PCTimestampNewer'
        $result.Message | Should -Be 'Selected the PC save because its latest file timestamp is newer (PC: 2026-03-14T12:00:00.0000000Z; Phone: 2026-03-14T08:00:00.0000000Z).'
    }

    It 'returns an ambiguity message when both saves have the same latest timestamp' {
        $pcPath = New-TestSaveSlot -RootPath $TestDrive -SlotName 'HintFarm_3' -PlayerName 'PC Farmer' -Money 100 -UiScale '0.80' -ZoomLevel '1.00' -MoveUpButton 'W' -ToolKey 'MouseLeft' -WindowMode 'Windowed'
        $phonePath = New-TestSaveSlot -RootPath $TestDrive -SlotName 'HintFarm_4' -PlayerName 'Phone Farmer' -Money 100 -UiScale '1.20' -ZoomLevel '1.10' -MoveUpButton 'TapNorth' -ToolKey 'TapTool' -WindowMode 'Fullscreen'
        Set-TestSaveSlotTimestamp -SlotPath $phonePath -Timestamp (Get-Date '2026-03-14T12:00:00Z')
        Set-TestSaveSlotTimestamp -SlotPath $pcPath -Timestamp (Get-Date '2026-03-14T12:00:00Z')

        $result = & (Get-Module StardewSaveBridge.Save) {
            param($innerPcPath, $innerPhonePath)
            Get-NewerSideHint -PCPath $innerPcPath -PhonePath $innerPhonePath
        } $pcPath $phonePath

        $result.Hint | Should -Be 'SameTimestamp'
        $result.ReasonCode | Should -Be 'SameTimestamp'
        $result.Message | Should -Be 'The newer side could not be determined safely because both saves have the same latest file timestamp (2026-03-14T12:00:00.0000000Z).'
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

    It 'returns a configured PC game version when pcGameExePath exists' {
        $config = Get-DefaultBridgeConfig
        $config.pcGameExePath = Get-TestExecutablePath

        $result = Get-PCGameVersion -Config $config

        $result.Detection | Should -Be 'Configured'
        $result.ResolvedPath | Should -Be $config.pcGameExePath
        $result.Parsed | Should -Not -BeNullOrEmpty
        $result.ShouldPersist | Should -BeFalse
        $result.Message | Should -BeNullOrEmpty
    }

    It 'auto-detects the PC executable from a Steam libraryfolders entry' {
        $config = Get-DefaultBridgeConfig
        $sourceExe = Get-TestExecutablePath
        $programFilesX86 = Join-Path -Path $TestDrive -ChildPath 'Program Files (x86)'
        $programFiles = Join-Path -Path $TestDrive -ChildPath 'Program Files'
        $steamRoot = Join-Path -Path $programFilesX86 -ChildPath 'Steam'
        $steamApps = Join-Path -Path $steamRoot -ChildPath 'steamapps'
        $libraryRoot = Join-Path -Path $TestDrive -ChildPath 'SteamLibraryD'
        $targetExe = Join-Path -Path $libraryRoot -ChildPath 'steamapps/common/Stardew Valley/Stardew Valley.exe'
        $libraryFoldersPath = Join-Path -Path $steamApps -ChildPath 'libraryfolders.vdf'
        $escapedLibraryRoot = ($libraryRoot -replace '\\', '\\\\')

        New-Item -ItemType Directory -Path (Split-Path -Path $targetExe -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path $steamApps -Force | Out-Null
        Copy-Item -LiteralPath $sourceExe -Destination $targetExe -Force
        @"
"libraryfolders"
{
    "1"
    {
        "path" "$escapedLibraryRoot"
    }
}
"@ | Set-Content -LiteralPath $libraryFoldersPath -Encoding UTF8

        $previousProgramFiles = $env:ProgramFiles
        $previousProgramFilesX86 = ${env:ProgramFiles(x86)}
        try {
            $env:ProgramFiles = $programFiles
            ${env:ProgramFiles(x86)} = $programFilesX86

            $result = Get-PCGameVersion -Config $config
        }
        finally {
            $env:ProgramFiles = $previousProgramFiles
            ${env:ProgramFiles(x86)} = $previousProgramFilesX86
        }

        $result.Detection | Should -Be 'AutoDetected'
        $result.ResolvedPath | Should -Be $targetExe
        $result.Parsed | Should -Not -BeNullOrEmpty
        $result.ShouldPersist | Should -BeTrue
        $result.Message | Should -Be ("PC game executable auto-detected at '$targetExe'. Saved to config/user.json.")
    }

    It 'reports a setup message when no PC executable can be auto-detected' {
        $config = Get-DefaultBridgeConfig
        $previousProgramFiles = $env:ProgramFiles
        $previousProgramFilesX86 = ${env:ProgramFiles(x86)}
        try {
            $env:ProgramFiles = Join-Path -Path $TestDrive -ChildPath 'EmptyProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path -Path $TestDrive -ChildPath 'EmptyProgramFilesX86'

            $result = Get-PCGameVersion -Config $config
        }
        finally {
            $env:ProgramFiles = $previousProgramFiles
            ${env:ProgramFiles(x86)} = $previousProgramFilesX86
        }

        $result.Detection | Should -Be 'NotConfigured'
        $result.Parsed | Should -Be $null
        $result.Message | Should -Be 'PC game version could not be determined. Set config/user.json -> pcGameExePath to your Stardew Valley executable, or install Stardew Valley in a supported Steam/GOG location.'
    }

    It 'reports a setup message when the configured pcGameExePath is stale' {
        $config = Get-DefaultBridgeConfig
        $config.pcGameExePath = Join-Path -Path $TestDrive -ChildPath 'missing/Stardew Valley.exe'

        $result = Get-PCGameVersion -Config $config

        $result.Detection | Should -Be 'MissingPath'
        $result.Parsed | Should -Be $null
        $result.Message | Should -Be "Configured pcGameExePath does not exist: '$($config.pcGameExePath)'. Set config/user.json -> pcGameExePath to the full path to 'Stardew Valley.exe', not the install folder."
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
