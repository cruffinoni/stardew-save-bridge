BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Workflow.psm1') -Force
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
            $result = Get-InspectRecommendation -OverallStatus 'Identical' -NewerSideHint 'Phone'

            $result | Should -Be 'Saves are identical. No handoff is needed.'
        }
    }

    It 'still suggests a likely newer side when saves differ' {
        InModuleScope StardewSaveBridge.Workflow {
            $result = Get-InspectRecommendation -OverallStatus 'Different' -NewerSideHint 'Phone'

            $result | Should -Be 'Phone save appears newer. Choose the version you want to keep.'
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
