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
        $runRecord.finalOutcome = 'Completed'

        Write-BridgeRunLog -Config $config -RepositoryRoot $TestDrive -RunRecord $runRecord

        @(Get-ChildItem -LiteralPath $config.logRoot -Filter '*.json').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $config.logRoot -Filter '*.log').Count | Should -Be 1
    }
}
