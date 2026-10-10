BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Core.psm1') -Force
    Import-Module (Join-Path -Path $repoRoot -ChildPath 'src/StardewSaveBridge.Adb.psm1') -Force
}

Describe 'Save copy helpers' {
    It 'pulls phone saves with timestamp preservation enabled' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{ adbPath = 'adb' }

            Mock Resolve-AdbPath { 'adb' } -ModuleName StardewSaveBridge.Adb
            Mock Ensure-BridgeDirectory { $true } -ModuleName StardewSaveBridge.Adb
            Mock Get-ActiveAndroidSaveRoot { '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves' } -ModuleName StardewSaveBridge.Adb
            Mock Test-Path { $false } -ModuleName StardewSaveBridge.Adb
            Mock Remove-Item {} -ModuleName StardewSaveBridge.Adb
            Mock Invoke-AdbCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Output = ''
                    Arguments = $Arguments
                }
            } -ModuleName StardewSaveBridge.Adb

            $targetPath = Join-Path -Path $TestDrive -ChildPath 'staging/Farm_123'
            $result = Copy-PhoneSaveToLocal -Config $config -DeviceId 'device-1' -SlotName 'Farm_123' -TargetPath $targetPath

            $result | Should -Be $targetPath
            Should -Invoke Invoke-AdbCommand -Exactly -Times 1 -ParameterFilter {
                $AdbPath -eq 'adb' -and
                $Arguments.Count -eq 6 -and
                $Arguments[0] -eq '-s' -and
                $Arguments[1] -eq 'device-1' -and
                $Arguments[2] -eq 'pull' -and
                $Arguments[3] -eq '-a' -and
                $Arguments[4] -eq '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves/Farm_123' -and
                $Arguments[5] -eq (Split-Path -Path $targetPath -Parent)
            } -ModuleName StardewSaveBridge.Adb
        }
    }
}

Describe 'Wireless adb helpers' {
    It 'builds the wireless endpoint from config' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }

            $result = Get-WirelessAdbEndpoint -Config $config

            $result | Should -Be '192.168.1.4:39101'
        }
    }

    It 'reports an available endpoint when adb says it is already connected' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{
                adbPath = 'adb'
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }

            Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Adb
            Mock Resolve-AdbPath { 'adb' } -ModuleName StardewSaveBridge.Adb
            Mock Invoke-AdbCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Output = 'already connected to 192.168.1.4:39101'
                    Arguments = @('connect', '192.168.1.4:39101')
                }
            } -ParameterFilter { $Arguments[0] -eq 'connect' } -ModuleName StardewSaveBridge.Adb
            Mock Get-AdbDeviceList {
                @([pscustomobject]@{ Id = '192.168.1.4:39101'; State = 'device' })
            } -ModuleName StardewSaveBridge.Adb

            $result = Connect-WirelessAdbDevice -Config $config

            $result.IsAvailable | Should -BeTrue
            $result.Status | Should -Be 'AlreadyConnected'
            $result.DeviceId | Should -Be '192.168.1.4:39101'
        }
    }

    It 'treats an unreachable endpoint as unavailable without throwing' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{
                adbPath = 'adb'
                wirelessDeviceHost = '192.168.1.4'
                wirelessDevicePort = 39101
            }

            Mock Test-AdbAvailable { $true } -ModuleName StardewSaveBridge.Adb
            Mock Resolve-AdbPath { 'adb' } -ModuleName StardewSaveBridge.Adb
            Mock Invoke-AdbCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Output = 'failed to connect to 192.168.1.4:39101'
                    Arguments = @('connect', '192.168.1.4:39101')
                }
            } -ParameterFilter { $Arguments[0] -eq 'connect' } -ModuleName StardewSaveBridge.Adb
            Mock Get-AdbDeviceList { @() } -ModuleName StardewSaveBridge.Adb

            $result = Connect-WirelessAdbDevice -Config $config

            $result.IsAvailable | Should -BeFalse
            $result.Status | Should -Be 'Unavailable'
            $result.Reason | Should -Match 'failed to connect'
        }
    }
}

Describe 'mDNS adb helpers' {
    It 'parses connectable and pairing mdns services' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{ adbPath = 'adb' }

            Mock Resolve-AdbPath { 'adb' } -ModuleName StardewSaveBridge.Adb
            Mock Invoke-AdbCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Output = @'
List of discovered mdns services
adb-Secure._adb-tls-connect._tcp    _adb-tls-connect._tcp    192.168.1.4:39101
adb-Legacy._adb._tcp                _adb._tcp                192.168.1.4:5555
adb-Pair._adb-tls-pairing._tcp      _adb-tls-pairing._tcp    192.168.1.4:37123
'@
                    Arguments = @('mdns', 'services')
                }
            } -ModuleName StardewSaveBridge.Adb

            $result = @(Get-AdbMdnsServices -Config $config)

            $result.Count | Should -Be 3
            $result[0].ServiceType | Should -Be '_adb-tls-connect._tcp'
            $result[0].IsConnectable | Should -BeTrue
            $result[1].Endpoint | Should -Be '192.168.1.4:5555'
            $result[2].IsConnectable | Should -BeFalse
        }
    }

    It 'prefers the secure mdns service for the same address' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{ adbPath = 'adb' }

            Mock Resolve-AdbPath { 'adb' } -ModuleName StardewSaveBridge.Adb
            Mock Get-AdbMdnsServices {
                @(
                    [pscustomobject]@{
                        Order = 0
                        ServiceName = 'adb-Legacy._adb._tcp'
                        ServiceType = '_adb._tcp'
                        Address = '192.168.1.4'
                        Port = 5555
                        Endpoint = '192.168.1.4:5555'
                        IsConnectable = $true
                        ServicePriority = 1
                    }
                    [pscustomobject]@{
                        Order = 1
                        ServiceName = 'adb-Secure._adb-tls-connect._tcp'
                        ServiceType = '_adb-tls-connect._tcp'
                        Address = '192.168.1.4'
                        Port = 39101
                        Endpoint = '192.168.1.4:39101'
                        IsConnectable = $true
                        ServicePriority = 0
                    }
                )
            } -ModuleName StardewSaveBridge.Adb
            Mock Invoke-AdbCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Output = 'connected'
                    Arguments = $Arguments
                }
            } -ParameterFilter { $Arguments[0] -eq 'connect' } -ModuleName StardewSaveBridge.Adb
            Mock Get-AdbDeviceList {
                @([pscustomobject]@{ Id = '192.168.1.4:39101'; State = 'device' })
            } -ModuleName StardewSaveBridge.Adb

            $result = @(Get-AdbMdnsDeviceList -Config $config)

            $result.Count | Should -Be 1
            $result[0].Id | Should -Be '192.168.1.4:39101'
            $result[0].ServiceType | Should -Be '_adb-tls-connect._tcp'
            Should -Invoke Invoke-AdbCommand -ParameterFilter { $Arguments[0] -eq 'connect' -and $Arguments[1] -eq '192.168.1.4:39101' } -Times 1 -Exactly -ModuleName StardewSaveBridge.Adb
        }
    }

    It 'skips mdns services that do not materialize as adb devices' {
        InModuleScope StardewSaveBridge.Adb {
            $config = @{ adbPath = 'adb' }

            Mock Resolve-AdbPath { 'adb' } -ModuleName StardewSaveBridge.Adb
            Mock Get-AdbMdnsServices {
                @(
                    [pscustomobject]@{
                        Order = 0
                        ServiceName = 'adb-Broken._adb-tls-connect._tcp'
                        ServiceType = '_adb-tls-connect._tcp'
                        Address = '192.168.1.8'
                        Port = 40000
                        Endpoint = '192.168.1.8:40000'
                        IsConnectable = $true
                        ServicePriority = 0
                    }
                    [pscustomobject]@{
                        Order = 1
                        ServiceName = 'adb-Good._adb-tls-connect._tcp'
                        ServiceType = '_adb-tls-connect._tcp'
                        Address = '192.168.1.9'
                        Port = 40001
                        Endpoint = '192.168.1.9:40001'
                        IsConnectable = $true
                        ServicePriority = 0
                    }
                )
            } -ModuleName StardewSaveBridge.Adb
            Mock Invoke-AdbCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Output = 'connected'
                    Arguments = $Arguments
                }
            } -ParameterFilter { $Arguments[0] -eq 'connect' } -ModuleName StardewSaveBridge.Adb
            Mock Get-AdbDeviceList {
                @([pscustomobject]@{ Id = '192.168.1.9:40001'; State = 'device' })
            } -ModuleName StardewSaveBridge.Adb

            $result = @(Get-AdbMdnsDeviceList -Config $config)

            $result.Count | Should -Be 1
            $result[0].Id | Should -Be '192.168.1.9:40001'
        }
    }
}
