BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
}

Describe 'UX copy' {
    It 'contains the required labels' {
        $labels = Get-BridgeUiLabels

        $labels.Values | Should -Contain 'Inspect saves'
        $labels.Values | Should -Contain 'Use PC save'
        $labels.Values | Should -Contain 'Use Phone save'
        $labels.Values | Should -Contain 'Restore backup'
    }

    It 'does not contain prohibited transport terms in the centralized labels' {
        $labels = Get-BridgeUiLabels
        $joined = ($labels.Values -join ' ').ToLowerInvariant()

        foreach ($term in @('push', 'pull', 'upload', 'download', 'mirror', 'source', 'destination')) {
            $joined | Should -Not -Match ('\b' + [regex]::Escape($term) + '\b')
        }
    }
}
