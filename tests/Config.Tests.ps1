BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
}

Describe 'Config loading' {
    It 'creates a user config with defaults when none exists' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'config/user.json'
        $defaultPath = Join-Path -Path $TestDrive -ChildPath 'config/default.json'
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force | Out-Null
        @'
{
  "adbPath": "adb",
  "backupRoot": "backups"
}
'@ | Set-Content -LiteralPath $defaultPath -Encoding UTF8

        $config = Initialize-BridgeConfig -ConfigPath $configPath -RepositoryRoot $TestDrive

        $config.adbPath | Should -Be 'adb'
        $config.backupRoot | Should -Be (Join-Path -Path $TestDrive -ChildPath 'backups')
        $config.wirelessDeviceHost | Should -Be ''
        $config.wirelessDevicePort | Should -Be 0
        $config.daemonIntervalMinutes | Should -Be 30
        (Test-Path -LiteralPath $configPath) | Should -BeTrue
    }

    It 'persists remembered preferences back to the config file' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'config/user.json'
        $defaultPath = Join-Path -Path $TestDrive -ChildPath 'config/default.json'
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force | Out-Null
        (Get-DefaultBridgeConfig | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $defaultPath -Encoding UTF8

        $config = Initialize-BridgeConfig -ConfigPath $configPath -RepositoryRoot $TestDrive
        Save-BridgePreferences -Config $config -ConfigPath $configPath -Preferences @{ preferredSaveSlot = 'Farm_1'; preferredDeviceId = 'device-1' }
        $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

        $saved.preferredSaveSlot | Should -Be 'Farm_1'
        $saved.preferredDeviceId | Should -Be 'device-1'
    }

    It 'persists daemon configuration values' {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'config/user.json'
        $defaultPath = Join-Path -Path $TestDrive -ChildPath 'config/default.json'
        New-Item -ItemType Directory -Path (Split-Path -Path $defaultPath -Parent) -Force | Out-Null
        (Get-DefaultBridgeConfig | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $defaultPath -Encoding UTF8

        $config = Initialize-BridgeConfig -ConfigPath $configPath -RepositoryRoot $TestDrive
        Save-BridgePreferences -Config $config -ConfigPath $configPath -Preferences @{ wirelessDeviceHost = '192.168.1.4'; wirelessDevicePort = 39101; daemonIntervalMinutes = 30 }
        $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

        $saved.wirelessDeviceHost | Should -Be '192.168.1.4'
        $saved.wirelessDevicePort | Should -Be 39101
        $saved.daemonIntervalMinutes | Should -Be 30
    }
}
