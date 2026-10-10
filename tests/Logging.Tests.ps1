BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
}

Describe 'Run logging' {
    It 'writes both json and text log outputs' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'config/user.json'
        $defaultPath = Join-Path -Path $TestDrive -ChildPath 'config/default.json'
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force | Out-Null
        (Get-DefaultBridgeConfig | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $defaultPath -Encoding UTF8

        $config = Initialize-BridgeConfig -ConfigPath $configPath -RepositoryRoot $TestDrive
        $config.logRoot = Join-Path -Path $TestDrive -ChildPath 'logs'
        $runRecord = New-BridgeRunRecord -Action 'Inspect' -ConfigPath $config._configPath
        $runRecord.selectedSaveSlot = 'Farm_1'
        $runRecord.detectedPaths = @{ pcRoot = 'C:\Saves'; androidRoot = '/sdcard/Saves' }
        $runRecord.deviceSelection = @{
            message = 'Selected device: adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101) via mDNS (auto-selected)'
        }
        $runRecord.syncResults = @(
            [pscustomobject]@{
                SlotName = 'Farm_1'
                Status = 'SkippedCompatibility'
                SourceSide = 'Phone'
                TargetSide = 'PC'
                Reason = 'PC game version could not be determined. Set config/user.json -> pcGameExePath to your Stardew Valley executable, or install Stardew Valley in a supported Steam/GOG location.'
            }
        )
        $runRecord.finalOutcome = 'Completed'

        Write-BridgeRunLog -Config $config -RepositoryRoot $TestDrive -RunRecord $runRecord

        @(Get-ChildItem -LiteralPath $config.logRoot -Filter '*.json').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $config.logRoot -Filter '*.log').Count | Should -Be 1
        $textLog = Get-Content -LiteralPath @(Get-ChildItem -LiteralPath $config.logRoot -Filter '*.log' | Select-Object -First 1).FullName -Raw
        $textLog | Should -Match 'Device Selection: Selected device: adb-Secure\._adb-tls-connect\._tcp \(192\.168\.1\.4:39101\) via mDNS \(auto-selected\)'
        $textLog | Should -Match 'Per-slot Results:'
        $textLog | Should -Match 'Farm_1: SkippedCompatibility \[Phone->PC\] - PC game version could not be determined\. Set config/user\.json -> pcGameExePath to your Stardew Valley executable, or install Stardew Valley in a supported Steam/GOG location\.'
    }
}
