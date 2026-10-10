BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Adb.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Workflow.psm1') -Force
}

Describe 'Workflow device selection' {
    It 'auto-selects the first mdns device and marks it as visible to the user' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                preferredDeviceId = ''
                uiMode = 'Text'
            }

            Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
            Mock Get-AdbMdnsDeviceList {
                @(
                    [pscustomobject]@{
                        Id = '192.168.1.4:39101'
                        State = 'device'
                        DiscoverySource = 'mDNS'
                        ServiceName = 'adb-Secure._adb-tls-connect._tcp'
                        ServiceType = '_adb-tls-connect._tcp'
                        Address = '192.168.1.4'
                        Port = 39101
                        DisplayName = 'adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101)'
                        SelectionReason = ''
                    }
                    [pscustomobject]@{
                        Id = '192.168.1.5:39101'
                        State = 'device'
                        DiscoverySource = 'mDNS'
                        ServiceName = 'adb-Second._adb-tls-connect._tcp'
                        ServiceType = '_adb-tls-connect._tcp'
                        Address = '192.168.1.5'
                        Port = 39101
                        DisplayName = 'adb-Second._adb-tls-connect._tcp (192.168.1.5:39101)'
                        SelectionReason = ''
                    }
                )
            } -ModuleName StardewSaveBridge.Workflow
            Mock Get-AdbDeviceList { @() } -ModuleName StardewSaveBridge.Workflow

            $result = Resolve-SelectedDevice -Config $config -NonInteractive

            $result.Id | Should -Be '192.168.1.4:39101'
            $result.SelectionReason | Should -Be 'AutoSelectedMdns'
            (Get-BridgeDeviceSelectionSummaryLine -Device $result) | Should -Be 'Selected device: adb-Secure._adb-tls-connect._tcp (192.168.1.4:39101) via mDNS (auto-selected)'
        }
    }

    It 'prefers a saved device id before mdns auto-selection' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                preferredDeviceId = 'device-2'
                uiMode = 'Text'
            }

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
            Mock Get-AdbDeviceList {
                @([pscustomobject]@{ Id = 'device-2'; State = 'device' })
            } -ModuleName StardewSaveBridge.Workflow

            $result = Resolve-SelectedDevice -Config $config -NonInteractive

            $result.Id | Should -Be 'device-2'
            $result.DiscoverySource | Should -Be 'USB'
            $result.SelectionReason | Should -Be 'PreferredDeviceId'
        }
    }

    It 'falls back to usb selection labels when mdns is unavailable' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                preferredDeviceId = ''
                uiMode = 'Text'
            }

            Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Workflow
            Mock Get-AdbMdnsDeviceList { @() } -ModuleName StardewSaveBridge.Workflow
            Mock Get-AdbDeviceList {
                @(
                    [pscustomobject]@{ Id = 'device-1'; State = 'device' },
                    [pscustomobject]@{ Id = 'device-2'; State = 'device' }
                )
            } -ModuleName StardewSaveBridge.Workflow
            Mock Select-BridgeItem {
                param($Items, $Title, $LabelScript, $UiMode, $NonInteractive)
                $Title | Should -Be 'Choose a phone device'
                (& $LabelScript $Items[0]) | Should -Be 'device-1 [device] via USB'
                return $Items[1]
            } -ModuleName StardewSaveBridge.Workflow

            $result = Resolve-SelectedDevice -Config $config

            $result.Id | Should -Be 'device-2'
            $result.SelectionReason | Should -Be 'UsbPromptSelection'
        }
    }
}

Describe 'Workflow slot selection' {
    It 'does not concatenate the slot name when exactly one slot exists on both sides' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                preferredSaveSlot = ''
                uiMode = 'Text'
            }

            $pcSlots = @([pscustomobject]@{ Name = 'Alea_iacta_est_432990435'; Path = 'C:\Fake' ; Side = 'PC' })
            $phoneSlots = @([pscustomobject]@{ Name = 'Alea_iacta_est_432990435'; Path = '/sdcard/Fake'; Side = 'Phone' })

            $result = Resolve-SelectedSaveSlot -Config $config -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive

            $result | Should -Be 'Alea_iacta_est_432990435'
        }
    }

    It 'requires an explicit slot in non-interactive mode when multiple slots exist' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                preferredSaveSlot = 'Alea_432990435'
                uiMode = 'Text'
            }

            $pcSlots = @(
                [pscustomobject]@{ Name = 'Alea_432990435'; Path = 'C:\FakeA'; Side = 'PC' },
                [pscustomobject]@{ Name = 'Alea_iacta_est_432990435'; Path = 'C:\FakeB'; Side = 'PC' }
            )
            $phoneSlots = @(
                [pscustomobject]@{ Name = 'Alea_iacta_est_432990435'; Path = '/sdcard/Fake'; Side = 'Phone' }
            )

            { Resolve-SelectedSaveSlot -Config $config -PcSlots $pcSlots -PhoneSlots $phoneSlots -NonInteractive } |
                Should -Throw 'Multiple save slots found. Re-run with -SaveSlot or SLOT=<name>.'
        }
    }

    It 'prompts for a slot when multiple slots exist even if a preferred slot is set' {
        InModuleScope StardewSaveBridge.Workflow {
            $config = @{
                preferredSaveSlot = 'Alea_432990435'
                uiMode = 'Text'
            }

            $pcSlots = @(
                [pscustomobject]@{ Name = 'Alea_432990435'; Path = 'C:\FakeA'; Side = 'PC' },
                [pscustomobject]@{ Name = 'Alea_iacta_est_432990435'; Path = 'C:\FakeB'; Side = 'PC' }
            )
            $phoneSlots = @(
                [pscustomobject]@{ Name = 'Alea_iacta_est_432990435'; Path = '/sdcard/Fake'; Side = 'Phone' }
            )

            Mock Select-BridgeItem {
                param($Items, $Title, $LabelScript, $UiMode, $NonInteractive)
                $Title | Should -Be 'Choose a save slot'
                $Items[0].Name | Should -Be 'Alea_432990435'
                $Items[0].IsPreferred | Should -BeTrue
                & $LabelScript $Items[0] | Should -Be 'Alea_432990435 (last used)'
                return $Items[1]
            } -ModuleName StardewSaveBridge.Workflow

            $result = Resolve-SelectedSaveSlot -Config $config -PcSlots $pcSlots -PhoneSlots $phoneSlots

            $result | Should -Be 'Alea_iacta_est_432990435'
        }
    }
}

Describe 'Inspect recommendation' {
    It 'does not suggest a side when saves are identical' {
        InModuleScope StardewSaveBridge.Workflow {
            $result = Get-InspectRecommendation -OverallStatus 'Identical' -NewerSideHint ([pscustomobject]@{
                Hint = 'Phone'
                Message = 'Selected the phone save because its latest file timestamp is newer (PC: 2026-03-14T08:00:00.0000000Z; Phone: 2026-03-14T12:00:00.0000000Z).'
            })

            $result | Should -Be 'Saves are identical. No handoff is needed.'
        }
    }

    It 'still suggests a likely newer side when saves differ' {
        InModuleScope StardewSaveBridge.Workflow {
            $result = Get-InspectRecommendation -OverallStatus 'Different' -NewerSideHint ([pscustomobject]@{
                Hint = 'Phone'
                Message = 'Selected the phone save because its latest file timestamp is newer (PC: 2026-03-14T08:00:00.0000000Z; Phone: 2026-03-14T12:00:00.0000000Z).'
            })

            $result | Should -Be 'Selected the phone save because its latest file timestamp is newer (PC: 2026-03-14T08:00:00.0000000Z; Phone: 2026-03-14T12:00:00.0000000Z). Choose the version you want to keep.'
        }
    }

    It 'explains ambiguous recommendations when the newer side cannot be determined' {
        InModuleScope StardewSaveBridge.Workflow {
            $result = Get-InspectRecommendation -OverallStatus 'Different' -NewerSideHint ([pscustomobject]@{
                Hint = 'SameTimestamp'
                Message = 'The newer side could not be determined safely because both saves have the same latest file timestamp (2026-03-14T12:00:00.0000000Z).'
            })

            $result | Should -Be 'The newer side could not be determined safely because both saves have the same latest file timestamp (2026-03-14T12:00:00.0000000Z). Review the comparison before choosing the version you want to keep.'
        }
    }
}

Describe 'Summary formatting' {
    It 'formats a dry-run no-backup-needed line' {
        InModuleScope StardewSaveBridge.Workflow {
            $backupResult = [pscustomobject]@{
                Created = $false
                DryRun = $true
                BackupPath = $null
            }

            $result = Get-BackupSummaryLine -BackupResult $backupResult -NoBackupNeededMessage 'No existing phone save was found, so no backup was needed.'

            $result | Should -Be 'No existing phone save was found, so no backup was needed.'
        }
    }

    It 'formats a dry-run planned backup path line' {
        InModuleScope StardewSaveBridge.Workflow {
            $backupResult = [pscustomobject]@{
                Created = $false
                DryRun = $true
                BackupPath = 'C:\Backups\Slot\Phone\20260313-000000000'
            }

            $result = Get-BackupSummaryLine -BackupResult $backupResult -NoBackupNeededMessage 'unused'

            $result | Should -Be 'Dry-run: backup would be created at C:\Backups\Slot\Phone\20260313-000000000'
        }
    }

    It 'formats a create-on-phone dry-run line' {
        InModuleScope StardewSaveBridge.Workflow {
            $result = Get-TargetActionSummaryLine -Side 'Phone' -TargetExists:$false -DryRun

            $result | Should -Be 'This action would create the save on the phone.'
        }
    }

    It 'formats a verification skipped line for dry-run' {
        InModuleScope StardewSaveBridge.Workflow {
            $result = Get-VerificationSummaryLine -VerificationResult ([pscustomobject]@{ Status = 'DryRun'; Reason = 'Verification skipped in dry-run mode.' })

            $result | Should -Be 'Verification skipped in dry-run mode.'
        }
    }
}
