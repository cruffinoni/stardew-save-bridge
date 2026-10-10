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

function Get-WirelessAdbEndpoint {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $host = [string]$Config.wirelessDeviceHost
    if ([string]::IsNullOrWhiteSpace($host)) {
        throw 'wirelessDeviceHost must be configured for daemon mode.'
    }

    $port = 0
    if (-not [int]::TryParse([string]$Config.wirelessDevicePort, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'wirelessDevicePort must be configured with a valid TCP port for daemon mode.'
    }

    return ('{0}:{1}' -f $host.Trim(), $port)
}

function Connect-WirelessAdbDevice {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if (-not (Test-AdbAvailable -Config $Config)) {
        throw 'adb is not available. Install adb or set adbPath in the config file.'
    }

    $endpoint = Get-WirelessAdbEndpoint -Config $Config
    $adbPath = Resolve-AdbPath -Config $Config
    $connectResult = Invoke-AdbCommand -AdbPath $adbPath -Arguments @('connect', $endpoint) -AllowedExitCodes @(0, 1)
    $device = Get-AdbDeviceList -Config $Config | Where-Object { $_.Id -eq $endpoint } | Select-Object -First 1
    $state = if ($device) { $device.State } else { $null }
    $isAvailable = ($state -eq 'device')

    $status = if ($isAvailable) {
        if ($connectResult.Output -match 'already connected to') { 'AlreadyConnected' } else { 'Connected' }
    }
    elseif ($state) {
        'Unavailable'
    }
    else {
        'Unavailable'
    }

    $reason = if ($isAvailable) {
        $null
    }
    elseif ($state) {
        "Wireless adb device is in state '$state'."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($connectResult.Output)) {
        $connectResult.Output
    }
    else {
        'Wireless adb device is not reachable.'
    }

    return [pscustomobject]@{
        Endpoint = $endpoint
        DeviceId = if ($device) { $device.Id } else { $endpoint }
        Status = $status
        IsAvailable = $isAvailable
        State = $state
        Output = $connectResult.Output
        Reason = $reason
    }
}

function New-AdbDiscoveredDevice {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$State,

        [Parameter(Mandatory)]
        [string]$DiscoverySource,

        [string]$ServiceName,

        [string]$ServiceType,

        [string]$Address,

        [int]$Port,

        [string]$SelectionReason = '',

        [string]$DisplayName
    )

    $effectiveDisplayName = $DisplayName
    if ([string]::IsNullOrWhiteSpace($effectiveDisplayName)) {
        if ($DiscoverySource -eq 'mDNS' -and -not [string]::IsNullOrWhiteSpace($ServiceName)) {
            if (-not [string]::IsNullOrWhiteSpace($Address) -and $Port -gt 0) {
                $effectiveDisplayName = '{0} ({1}:{2})' -f $ServiceName, $Address, $Port
            }
            else {
                $effectiveDisplayName = $ServiceName
            }
        }
        else {
            $effectiveDisplayName = $Id
        }
    }

    return [pscustomobject]@{
        Id = $Id
        State = $State
        DiscoverySource = $DiscoverySource
        ServiceName = $ServiceName
        ServiceType = $ServiceType
        Address = $Address
        Port = $Port
        DisplayName = $effectiveDisplayName
        SelectionReason = $SelectionReason
    }
}

function Get-AdbMdnsServices {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $adbPath = Resolve-AdbPath -Config $Config

    try {
        $result = Invoke-AdbCommand -AdbPath $adbPath -Arguments @('mdns', 'services') -AllowedExitCodes @(0, 1)
    }
    catch {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    $services = @()
    $order = 0

    foreach ($line in ($result.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^(List of discovered mdns services|Service Name|no services found)') {
            continue
        }

        $parts = $trimmed -split '\s+'
        if ($parts.Count -lt 3) {
            continue
        }

        $endpointText = $parts[$parts.Count - 1]
        $serviceType = $parts[$parts.Count - 2]
        $serviceName = ($parts[0..($parts.Count - 3)] -join ' ').Trim()

        $address = $null
        $port = 0
        if ($endpointText -match '^(?<address>\[[^\]]+\]|[^:]+):(?<port>\d+)$') {
            $address = $matches.address.Trim('[', ']')
            [void][int]::TryParse($matches.port, [ref]$port)
        }

        $services += [pscustomobject]@{
            Order = $order
            ServiceName = $serviceName
            ServiceType = $serviceType
            Address = $address
            Port = $port
            Endpoint = if ($address -and $port -gt 0) { '{0}:{1}' -f $address, $port } else { $endpointText }
            IsConnectable = $serviceType -in @('_adb._tcp', '_adb-tls-connect._tcp')
            ServicePriority = if ($serviceType -eq '_adb-tls-connect._tcp') { 0 } elseif ($serviceType -eq '_adb._tcp') { 1 } else { 99 }
        }
        $order++
    }

    return $services
}

function Get-AdbMdnsDeviceList {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $services = @(Get-AdbMdnsServices -Config $Config | Where-Object {
        $_.IsConnectable -and -not [string]::IsNullOrWhiteSpace($_.Address) -and $_.Port -gt 0
    })
    if ($services.Count -eq 0) {
        return @()
    }

    $deduped = @{}
    foreach ($service in $services) {
        $dedupeKey = if ($service.Address) { $service.Address } else { $service.ServiceName }
        if (-not $deduped.ContainsKey($dedupeKey)) {
            $deduped[$dedupeKey] = $service
            continue
        }

        $existing = $deduped[$dedupeKey]
        if ($service.ServicePriority -lt $existing.ServicePriority) {
            $deduped[$dedupeKey] = $service
        }
    }

    $orderedServices = @($deduped.Values | Sort-Object -Property Order)
    $adbPath = Resolve-AdbPath -Config $Config
    foreach ($service in $orderedServices) {
        Invoke-AdbCommand -AdbPath $adbPath -Arguments @('connect', $service.Endpoint) -AllowedExitCodes @(0, 1) | Out-Null
    }

    try {
        $devices = @(Get-AdbDeviceList -Config $Config)
    }
    catch {
        return @()
    }

    $resolved = @()
    foreach ($service in $orderedServices) {
        $device = $devices | Where-Object { $_.Id -eq $service.Endpoint } | Select-Object -First 1
        if (-not $device) {
            continue
        }

        $resolved += New-AdbDiscoveredDevice `
            -Id $device.Id `
            -State $device.State `
            -DiscoverySource 'mDNS' `
            -ServiceName $service.ServiceName `
            -ServiceType $service.ServiceType `
            -Address $service.Address `
            -Port $service.Port
    }

    return $resolved
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
    Invoke-AdbCommand -AdbPath $adbPath -Arguments @('-s', $DeviceId, 'pull', '-a', $remotePath, $parentPath) | Out-Null
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
    'Get-WirelessAdbEndpoint',
    'Connect-WirelessAdbDevice',
    'Get-AdbMdnsServices',
    'Get-AdbMdnsDeviceList',
    'Get-AdbDeviceList',
    'Test-PhoneSaveRootAccess',
    'Get-PhoneSaveSlots',
    'Copy-PhoneSaveToLocal',
    'Copy-LocalSaveToPhone',
    'Get-PhoneGameVersion'
)
