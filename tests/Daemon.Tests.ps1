BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Save.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Adb.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Backup.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Workflow.psm1') -Force
}

Describe 'Daemon workflow' {
    It 'skips the cycle when no mdns or usb device is available' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }
            $runRecord = New-BridgeRunRecord -Action 'Daemon'

            Mock Resolve-SelectedDevice { throw 'No Android device is connected.' } -ModuleName StardewSaveBridge.Workflow

            $result = Invoke-DaemonSyncCycle -Config $config -RepositoryRoot $TestDrive -RunRecord $runRecord

            $result.FinalOutcome | Should -Be 'SkippedUnavailable'
            $runRecord.finalOutcome | Should -Be 'SkippedUnavailable'
            $runRecord.notes | Should -Contain 'No Android device is connected.'
        }
    }

    It 'skips the cycle when Stardew is running on the PC' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }
            $runRecord = New-BridgeRunRecord -Action 'Daemon'

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
            Mock Test-StardewRunning { $true } -ModuleName StardewSaveBridge.Workflow

            $result = Invoke-DaemonSyncCycle -Config $config -RepositoryRoot $TestDrive -RunRecord $runRecord

            $result.FinalOutcome | Should -Be 'SkippedPcGameRunning'
            $runRecord.finalOutcome | Should -Be 'SkippedPcGameRunning'
        }
    }

    It 'processes all discovered slots and summarizes mixed outcomes' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }
            $runRecord = New-BridgeRunRecord -Action 'Daemon'

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
            Mock Get-WindowsSaveRoot { 'C:\PcSaves' } -ModuleName StardewSaveBridge.Workflow
            Mock Get-LocalSaveSlots {
                @(
                    [pscustomobject]@{ Name = 'SlotA'; Path = 'C:\PcSaves\SlotA'; Side = 'PC' },
                    [pscustomobject]@{ Name = 'SlotB'; Path = 'C:\PcSaves\SlotB'; Side = 'PC' }
                )
            } -ModuleName StardewSaveBridge.Workflow
            Mock Get-PhoneSaveSlots {
                @(
                    [pscustomobject]@{ Name = 'SlotB'; Path = '/phone/SlotB'; Side = 'Phone' },
                    [pscustomobject]@{ Name = 'SlotC'; Path = '/phone/SlotC'; Side = 'Phone' }
                )
            } -ModuleName StardewSaveBridge.Workflow
            Mock Get-PCGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow
            Mock Get-PhoneGameVersion { [pscustomobject]@{ Raw = '1.6.15'; Parsed = [version]'1.6.15'; Source = 'mock' } } -ModuleName StardewSaveBridge.Workflow
            Mock Invoke-DaemonSlotSync {
                param($Config, $DeviceId, $AndroidSaveRoot, $SlotName, $PcPath, $PcGameVersion, $PhoneGameVersion, $DryRun)
                switch ($SlotName) {
                    'SlotA' { return [pscustomobject]@{ SlotName = 'SlotA'; Status = 'Synced'; SourceSide = 'PC'; TargetSide = 'Phone'; Reason = 'Selected the PC save because its latest file timestamp is newer (PC: 2026-03-14T12:00:00.0000000Z; Phone: 2026-03-14T08:00:00.0000000Z). Copied the PC save to the phone and verified the result.' } }
                    'SlotB' { return [pscustomobject]@{ SlotName = 'SlotB'; Status = 'AlreadySynced'; SourceSide = $null; TargetSide = $null; Reason = 'The PC and phone saves are already identical.' } }
                    default { return [pscustomobject]@{ SlotName = 'SlotC'; Status = 'SkippedAmbiguous'; SourceSide = $null; TargetSide = $null; Reason = 'The newer side could not be determined safely because both saves have the same latest file timestamp (2026-03-14T12:00:00.0000000Z).' } }
                }
            } -ModuleName StardewSaveBridge.Workflow

            $result = Invoke-DaemonSyncCycle -Config $config -RepositoryRoot $TestDrive -RunRecord $runRecord

            $result.FinalOutcome | Should -Be 'Completed'
            $result.OutputLines | Should -Contain 'Selected device: adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101) via mDNS (auto-selected)'
            $result.OutputLines | Should -Contain 'Detected Phone game version: 1.6.15'
            $result.OutputLines | Should -Contain 'Slot SlotA: Synced PC -> Phone - Selected the PC save because its latest file timestamp is newer (PC: 2026-03-14T12:00:00.0000000Z; Phone: 2026-03-14T08:00:00.0000000Z). Copied the PC save to the phone and verified the result.'
            $result.OutputLines | Should -Contain 'Slot SlotB: Already synced - The PC and phone saves are already identical.'
            $result.OutputLines | Should -Contain 'Slot SlotC: Skipped Ambiguous - The newer side could not be determined safely because both saves have the same latest file timestamp (2026-03-14T12:00:00.0000000Z).'
            $result.OutputLines | Should -Contain 'Slots checked: 3'
            $result.OutputLines | Should -Contain 'Slots synced: 1'
            $result.OutputLines | Should -Contain 'Slots already in sync: 1'
            $result.OutputLines | Should -Contain 'Slots skipped: 1'
            $runRecord.syncResults.Count | Should -Be 3
        }
    }

    It 'returns a PC executable preference update and message when auto-detection succeeds during a cycle' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }
            $runRecord = New-BridgeRunRecord -Action 'Daemon'
            $detectedPath = 'C:\Games\Stardew Valley\Stardew Valley.exe'

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
            Mock Get-WindowsSaveRoot { 'C:\PcSaves' } -ModuleName StardewSaveBridge.Workflow
            Mock Get-LocalSaveSlots { @() } -ModuleName StardewSaveBridge.Workflow
            Mock Get-PhoneSaveSlots { @() } -ModuleName StardewSaveBridge.Workflow
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

            $result = Invoke-DaemonSyncCycle -Config $config -RepositoryRoot $TestDrive -RunRecord $runRecord

            $result.OutputLines | Should -Contain 'Detected PC game version: 1.6.15'
            $result.OutputLines | Should -Contain 'Detected Phone game version: 1.6.15'
            $result.Preferences.pcGameExePath | Should -Be $detectedPath
            $result.OutputLines | Should -Contain "PC game executable auto-detected at '$detectedPath'. Saved to config/user.json."
        }
    }

    It 'stops the daemon after the first cycle when PC game version is unknown for phone-to-pc sync' {
        InModuleScope StardewSaveBridge.Workflow {
            $configPath = Join-Path -Path $TestDrive -ChildPath 'config/user.json'
            $defaultPath = Join-Path -Path $TestDrive -ChildPath 'config/default.json'
            New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force | Out-Null
            (Get-DefaultBridgeConfig | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $defaultPath -Encoding UTF8

            $config = Initialize-BridgeConfig -ConfigPath $configPath -RepositoryRoot $TestDrive
            $config.daemonIntervalMinutes = 1

            Mock Invoke-DaemonSyncCycle {
                param($Config, $RepositoryRoot, $DryRun, $RunRecord)
                $RunRecord['syncResults'] = @(
                    [pscustomobject]@{
                        SlotName = 'Farm_1'
                        Status = 'SkippedCompatibility'
                        SourceSide = 'Phone'
                        TargetSide = 'PC'
                        Reason = 'PC game version could not be determined. Set config/user.json -> pcGameExePath to your Stardew Valley executable, or install Stardew Valley in a supported Steam/GOG location.'
                    }
                )

                [pscustomobject]@{
                    ExitCode = 0
                    FinalOutcome = 'Completed'
                    Compatibility = [ordered]@{
                        pcGameVersion = $null
                        phoneGameVersion = '1.6.15'
                    }
                    ComparisonSummary = @{}
                    OverwriteTarget = ''
                    VerificationResult = @{}
                    Errors = @()
                    Preferences = @{}
                    OutputLines = @()
                }
            } -ModuleName StardewSaveBridge.Workflow
            Mock Write-BridgeRunLog { [pscustomobject]@{ TextPath = $null } } -ModuleName StardewSaveBridge.Workflow
            Mock Wait-BridgeDaemonInterval {} -ModuleName StardewSaveBridge.Workflow
            Mock Write-Warning {} -ModuleName StardewSaveBridge.Workflow

            Start-BridgeDaemon -Config $config -RepositoryRoot $TestDrive

            Should -Invoke Wait-BridgeDaemonInterval -ModuleName StardewSaveBridge.Workflow -Times 0
            Should -Invoke Write-Warning -ModuleName StardewSaveBridge.Workflow -Times 1 -Exactly
        }
    }

    It 'persists daemon preference updates to config/user.json between cycles' {
        InModuleScope StardewSaveBridge.Workflow {
            $configPath = Join-Path -Path $TestDrive -ChildPath 'config/user.json'
            $defaultPath = Join-Path -Path $TestDrive -ChildPath 'config/default.json'
            New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force | Out-Null
            (Get-DefaultBridgeConfig | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $defaultPath -Encoding UTF8

            $config = Initialize-BridgeConfig -ConfigPath $configPath -RepositoryRoot $TestDrive
            $config.daemonIntervalMinutes = 1

            Mock Invoke-DaemonSyncCycle {
                [pscustomobject]@{
                    ExitCode = 0
                    FinalOutcome = 'Completed'
                    Compatibility = @{}
                    ComparisonSummary = @{}
                    OverwriteTarget = ''
                    VerificationResult = @{}
                    Errors = @()
                    Preferences = @{ pcGameExePath = 'C:\Games\Stardew Valley\Stardew Valley.exe' }
                    OutputLines = @()
                }
            } -ModuleName StardewSaveBridge.Workflow
            Mock Write-BridgeRunLog { [pscustomobject]@{ TextPath = $null } } -ModuleName StardewSaveBridge.Workflow
            Mock Wait-BridgeDaemonInterval { throw 'StopDaemonLoop' } -ModuleName StardewSaveBridge.Workflow

            { Start-BridgeDaemon -Config $config -RepositoryRoot $TestDrive } | Should -Throw 'StopDaemonLoop'

            $savedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $savedConfig.pcGameExePath | Should -Be 'C:\Games\Stardew Valley\Stardew Valley.exe'
        }
    }
}
