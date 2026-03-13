Set-StrictMode -Version Latest

function Resolve-AdbPath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    return $Config.adbPath
}

function Normalize-AndroidShellPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalized = $Path.Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return '/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves'
    }

    if ($normalized.StartsWith('/')) {
        return $normalized.TrimEnd('/')
    }

    if ($normalized.StartsWith('sdcard/')) {
        return ('/' + $normalized.TrimEnd('/'))
    }

    return ('/sdcard/' + $normalized.TrimStart('/').TrimEnd('/'))
}

function Get-AndroidSaveRootCandidates {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $primary = Normalize-AndroidShellPath -Path $Config.androidSaveRoot
    $candidates = @($primary)

    if ($primary.StartsWith('/sdcard/')) {
        $candidates += ('/storage/emulated/0/' + $primary.Substring('/sdcard/'.Length))
    }
    elseif ($primary.StartsWith('/storage/emulated/0/')) {
        $candidates += ('/sdcard/' + $primary.Substring('/storage/emulated/0/'.Length))
    }

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-ActiveAndroidSaveRoot {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$DeviceId
    )

    if ($Config.ContainsKey('_resolvedAndroidSaveRoot') -and -not [string]::IsNullOrWhiteSpace($Config._resolvedAndroidSaveRoot)) {
        return $Config._resolvedAndroidSaveRoot
    }

    $candidates = Get-AndroidSaveRootCandidates -Config $Config

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        return $candidates[0]
    }

    $adbPath = Resolve-AdbPath -Config $Config
    foreach ($candidate in $candidates) {
        $result = Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'shell', 'ls', $candidate) -AllowedExitCodes @(0, 1)
        if ($result.ExitCode -eq 0 -and $result.Output -notmatch 'No such file|Permission denied|inaccessible|cannot access') {
            $Config['_resolvedAndroidSaveRoot'] = $candidate
            return $candidate
        }
    }

    throw ("The Android save path cannot be accessed through adb. Tried: {0}" -f ($candidates -join ', '))
}

function Invoke-AdbCommand {
    param(
        [Parameter(Mandatory)]
        [string]$AdbPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [int[]]$AllowedExitCodes = @(0)
    )

    $output = & $AdbPath @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "adb command failed ($exitCode): $AdbPath $($Arguments -join ' ')`n$output"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output.Trim()
        Arguments = $Arguments
    }
}

function Test-AdbAvailable {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $adbPath = Resolve-AdbPath -Config $Config

    try {
        Invoke-AdbCommand -AdbPath $adbPath -Arguments @('version') | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-AdbDeviceList {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $adbPath = Resolve-AdbPath -Config $Config
    $result = Invoke-AdbCommand -AdbPath $adbPath -Arguments @('devices')
    $devices = @()

    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^(List of devices attached|\s*$)') {
            continue
        }

        $parts = $line -split '\s+'
        if ($parts.Count -lt 2) {
            continue
        }

        $devices += [pscustomobject]@{
            Id = $parts[0]
            State = $parts[1]
        }
    }

    return $devices
}

function Test-PhoneSaveRootAccess {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DeviceId
    )

    try {
        Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $DeviceId | Out-Null
    }
    catch {
        return $false
    }

    return $true
}

function Get-PhoneSaveSlots {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DeviceId
    )

    $adbPath = Resolve-AdbPath -Config $Config
    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $DeviceId
    $result = Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'shell', 'ls', '-1', $androidSaveRoot)

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    return ($result.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object) | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Trim()
            Path = ($androidSaveRoot.TrimEnd('/') + '/' + $_.Trim())
            Side = 'Phone'
        }
    }
}

function Copy-PhoneSaveToLocal {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DeviceId,

        [Parameter(Mandatory)]
        [string]$SlotName,

        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    $adbPath = Resolve-AdbPath -Config $Config
    $parentPath = Split-Path -Path $TargetPath -Parent

    Ensure-BridgeDirectory -Path $parentPath | Out-Null
    if (Test-Path -LiteralPath $TargetPath) {
        Remove-Item -LiteralPath $TargetPath -Recurse -Force
    }

    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $DeviceId
    $remotePath = $androidSaveRoot.TrimEnd('/') + '/' + $SlotName
    Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'pull', $remotePath, $parentPath) | Out-Null
    return $TargetPath
}

function Copy-LocalSaveToPhone {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DeviceId,

        [Parameter(Mandatory)]
        [string]$LocalSlotPath
    )

    $adbPath = Resolve-AdbPath -Config $Config
    $slotName = Split-Path -Path $LocalSlotPath -Leaf
    $androidSaveRoot = Get-ActiveAndroidSaveRoot -Config $Config -DeviceId $DeviceId
    $remoteSlotPath = $androidSaveRoot.TrimEnd('/') + '/' + $slotName

    Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'shell', 'mkdir', '-p', $androidSaveRoot) | Out-Null
    Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'shell', 'rm', '-rf', $remoteSlotPath) | Out-Null
    Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'push', $LocalSlotPath, ($androidSaveRoot.TrimEnd('/') + '/')) | Out-Null
}

function Get-PhoneGameVersion {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [string]$DeviceId
    )

    $adbPath = Resolve-AdbPath -Config $Config
    $packageName = if ([string]::IsNullOrWhiteSpace($Config.phonePackageName)) { 'com.chucklefish.stardewvalley' } else { $Config.phonePackageName }
    $result = Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'shell', 'dumpsys', 'package', $packageName) -AllowedExitCodes @(0, 1)

    $versionLine = $result.Output -split "`r?`n" | Where-Object { $_ -match 'versionName=' } | Select-Object -First 1
    if (-not $versionLine) {
        return [pscustomobject]@{
            Raw = $null
            Parsed = $null
            Source = 'adb:dumpsys'
        }
    }

    $rawVersion = ($versionLine -replace '.*versionName=', '').Trim()
    return [pscustomobject]@{
        Raw = $rawVersion
        Parsed = ConvertTo-BridgeVersion -Text $rawVersion
        Source = 'adb:dumpsys'
    }
}

Export-ModuleMember -Function @(
    'Resolve-AdbPath',
    'Invoke-AdbCommand',
    'Normalize-AndroidShellPath',
    'Get-AndroidSaveRootCandidates',
    'Get-ActiveAndroidSaveRoot',
    'Test-AdbAvailable',
    'Get-AdbDeviceList',
    'Test-PhoneSaveRootAccess',
    'Get-PhoneSaveSlots',
    'Copy-PhoneSaveToLocal',
    'Copy-LocalSaveToPhone',
    'Get-PhoneGameVersion'
)
