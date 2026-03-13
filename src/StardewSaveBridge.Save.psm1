Set-StrictMode -Version Latest

function Get-WindowsSaveRoot {
    $appData = $env:APPDATA

    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData/Roaming'
    }

    return Join-Path -Path $appData -ChildPath 'StardewValley/Saves'
}

function Get-LocalSaveSlots {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$Side
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $RootPath -Directory | Sort-Object -Property Name | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            Path = $_.FullName
            Side = $Side
        }
    }
}

function Resolve-MainSaveFile {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath
    )

    $slotName = Split-Path -Path $FolderPath -Leaf
    $expected = Join-Path -Path $FolderPath -ChildPath $slotName

    if (Test-Path -LiteralPath $expected -PathType Leaf) {
        return $expected
    }

    $candidate = Get-ChildItem -LiteralPath $FolderPath -File |
        Where-Object { $_.Name -ne 'SaveGameInfo' -and $_.Name -notlike '*_old' } |
        Sort-Object -Property Name |
        Select-Object -First 1

    if ($candidate) {
        return $candidate.FullName
    }

    return $null
}

function Find-XmlNodeValue {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlNode]$Node,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($Node.NodeType -eq [System.Xml.XmlNodeType]::Element -and $Names -contains $Node.Name -and -not [string]::IsNullOrWhiteSpace($Node.InnerText)) {
        return $Node.InnerText.Trim()
    }

    foreach ($child in $Node.ChildNodes) {
        $match = Find-XmlNodeValue -Node $child -Names $Names
        if ($match) {
            return $match
        }
    }

    return $null
}

function ConvertTo-BridgeVersion {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '\d+(\.\d+){0,3}')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Value
    }
    catch {
        return $null
    }
}

function Get-SaveVersionInfo {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return [pscustomobject]@{
            Raw = $null
            Parsed = $null
            SourcePath = $null
        }
    }

    $mainFile = Resolve-MainSaveFile -FolderPath $FolderPath
    $candidates = @()

    if ($mainFile) {
        $candidates += $mainFile
    }

    $infoFile = Join-Path -Path $FolderPath -ChildPath 'SaveGameInfo'
    if (Test-Path -LiteralPath $infoFile) {
        $candidates += $infoFile
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            [xml]$xml = Get-Content -LiteralPath $candidate -Raw
            $rawValue = Find-XmlNodeValue -Node $xml.DocumentElement -Names @('gameVersion', 'GameVersion', 'version', 'Version')
            if ($rawValue) {
                return [pscustomobject]@{
                    Raw = $rawValue
                    Parsed = ConvertTo-BridgeVersion -Text $rawValue
                    SourcePath = $candidate
                }
            }
        }
        catch {
            continue
        }
    }

    return [pscustomobject]@{
        Raw = $null
        Parsed = $null
        SourcePath = $null
    }
}

function Test-SaveXmlReadability {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        [xml](Get-Content -LiteralPath $Path -Raw) | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Test-SaveFolder {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath,

        [switch]$SkipXmlCheck
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return [pscustomobject]@{
            Exists = $false
            IsValid = $false
            MissingFiles = @('FolderMissing')
            MainSaveFile = $null
            SaveGameInfoPath = $null
            HasOldFiles = $false
            OldFiles = @()
            XmlReadable = $false
            SaveVersion = Get-SaveVersionInfo -FolderPath $FolderPath
            LatestWriteTimeUtc = $null
        }
    }

    $mainSaveFile = Resolve-MainSaveFile -FolderPath $FolderPath
    $saveGameInfoPath = Join-Path -Path $FolderPath -ChildPath 'SaveGameInfo'
    $missing = @()

    if (-not $mainSaveFile) {
        $missing += 'MainSaveFile'
    }

    if (-not (Test-Path -LiteralPath $saveGameInfoPath -PathType Leaf)) {
        $missing += 'SaveGameInfo'
    }

    $oldFiles = @(Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_old' } | Select-Object -ExpandProperty Name)
    $latestFile = Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $latestWriteTime = if ($latestFile) { $latestFile.LastWriteTimeUtc } else { $null }

    $xmlReadable = $true
    if (-not $SkipXmlCheck -and $missing.Count -eq 0) {
        $xmlReadable = (Test-SaveXmlReadability -Path $mainSaveFile) -and (Test-SaveXmlReadability -Path $saveGameInfoPath)
    }

    return [pscustomobject]@{
        Exists = $true
        IsValid = ($missing.Count -eq 0 -and $xmlReadable)
        MissingFiles = $missing
        MainSaveFile = $mainSaveFile
        SaveGameInfoPath = if (Test-Path -LiteralPath $saveGameInfoPath -PathType Leaf) { $saveGameInfoPath } else { $null }
        HasOldFiles = ($oldFiles.Count -gt 0)
        OldFiles = $oldFiles
        XmlReadable = $xmlReadable
        SaveVersion = Get-SaveVersionInfo -FolderPath $FolderPath
        LatestWriteTimeUtc = $latestWriteTime
    }
}

function Get-SaveManifest {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $FolderPath -Recurse -File | Sort-Object -Property FullName | ForEach-Object {
        [pscustomobject]@{
            RelativePath = Get-BridgeRelativePath -RootPath $FolderPath -ChildPath $_.FullName
            FullName = $_.FullName
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            Length = $_.Length
            LastWriteTimeUtc = $_.LastWriteTimeUtc
        }
    }
}

function Compare-SaveFolders {
    param(
        [string]$PCPath,
        [string]$PhonePath
    )

    $pcManifest = @()
    $phoneManifest = @()

    if ($PCPath) {
        $pcManifest = Get-SaveManifest -FolderPath $PCPath
    }

    if ($PhonePath) {
        $phoneManifest = Get-SaveManifest -FolderPath $PhonePath
    }

    $pcByPath = @{}
    foreach ($item in $pcManifest) {
        $pcByPath[$item.RelativePath] = $item
    }

    $phoneByPath = @{}
    foreach ($item in $phoneManifest) {
        $phoneByPath[$item.RelativePath] = $item
    }

    $allPaths = @($pcByPath.Keys + $phoneByPath.Keys | Sort-Object -Unique)
    $differences = @()

    foreach ($relativePath in $allPaths) {
        if (-not $pcByPath.ContainsKey($relativePath)) {
            $differences += [pscustomobject]@{
                RelativePath = $relativePath
                Classification = 'OnlyOnPhone'
            }
            continue
        }

        if (-not $phoneByPath.ContainsKey($relativePath)) {
            $differences += [pscustomobject]@{
                RelativePath = $relativePath
                Classification = 'OnlyOnPC'
            }
            continue
        }

        if ($pcByPath[$relativePath].Hash -eq $phoneByPath[$relativePath].Hash) {
            $differences += [pscustomobject]@{
                RelativePath = $relativePath
                Classification = 'Identical'
            }
        }
        else {
            $differences += [pscustomobject]@{
                RelativePath = $relativePath
                Classification = 'ContentDiffers'
            }
        }
    }

    $overallStatus = if ($differences.Count -gt 0 -and ($differences | Where-Object { $_.Classification -ne 'Identical' })) {
        'Different'
    }
    else {
        'Identical'
    }

    return [pscustomobject]@{
        OverallStatus = $overallStatus
        Files = $differences
        Summary = [ordered]@{
            identical = @($differences | Where-Object { $_.Classification -eq 'Identical' }).Count
            onlyOnPC = @($differences | Where-Object { $_.Classification -eq 'OnlyOnPC' }).Count
            onlyOnPhone = @($differences | Where-Object { $_.Classification -eq 'OnlyOnPhone' }).Count
            contentDiffers = @($differences | Where-Object { $_.Classification -eq 'ContentDiffers' }).Count
            totalFiles = $differences.Count
        }
        NewerSideHint = Get-NewerSideHint -PCPath $PCPath -PhonePath $PhonePath
    }
}

function Get-NewerSideHint {
    param(
        [string]$PCPath,
        [string]$PhonePath
    )

    $pcLatest = $null
    $phoneLatest = $null

    if ($PCPath -and (Test-Path -LiteralPath $PCPath)) {
        $pcLatestFile = Get-ChildItem -LiteralPath $PCPath -Recurse -File | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1
        $pcLatest = if ($pcLatestFile) { $pcLatestFile.LastWriteTimeUtc } else { $null }
    }

    if ($PhonePath -and (Test-Path -LiteralPath $PhonePath)) {
        $phoneLatestFile = Get-ChildItem -LiteralPath $PhonePath -Recurse -File | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1
        $phoneLatest = if ($phoneLatestFile) { $phoneLatestFile.LastWriteTimeUtc } else { $null }
    }

    if (-not $pcLatest -and -not $phoneLatest) {
        return [pscustomobject]@{
            Hint = 'Unknown'
            PC = $null
            Phone = $null
        }
    }

    if ($pcLatest -and -not $phoneLatest) {
        return [pscustomobject]@{
            Hint = 'PC'
            PC = $pcLatest
            Phone = $null
        }
    }

    if ($phoneLatest -and -not $pcLatest) {
        return [pscustomobject]@{
            Hint = 'Phone'
            PC = $null
            Phone = $phoneLatest
        }
    }

    if ($pcLatest -gt $phoneLatest) {
        return [pscustomobject]@{
            Hint = 'PC'
            PC = $pcLatest
            Phone = $phoneLatest
        }
    }

    if ($phoneLatest -gt $pcLatest) {
        return [pscustomobject]@{
            Hint = 'Phone'
            PC = $pcLatest
            Phone = $phoneLatest
        }
    }

    return [pscustomobject]@{
        Hint = 'SameTimestamp'
        PC = $pcLatest
        Phone = $phoneLatest
    }
}

function Get-PCGameVersion {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.pcGameExePath)) {
        return [pscustomobject]@{
            Raw = $null
            Parsed = $null
            Source = 'NotConfigured'
        }
    }

    $exePath = $Config.pcGameExePath
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        return [pscustomobject]@{
            Raw = $null
            Parsed = $null
            Source = 'MissingPath'
        }
    }

    $rawVersion = (Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
    return [pscustomobject]@{
        Raw = $rawVersion
        Parsed = ConvertTo-BridgeVersion -Text $rawVersion
        Source = $exePath
    }
}

function Test-VersionCompatibility {
    param(
        [version]$SaveVersion,
        [version]$TargetGameVersion
    )

    if (-not $SaveVersion -or -not $TargetGameVersion) {
        return [pscustomobject]@{
            Status = 'Unknown'
            Reason = 'Game version or save version is unavailable.'
        }
    }

    if ($SaveVersion -gt $TargetGameVersion) {
        return [pscustomobject]@{
            Status = 'Blocked'
            Reason = 'The save appears newer than the target game version.'
        }
    }

    return [pscustomobject]@{
        Status = 'Safe'
        Reason = 'The target game version can load this save.'
    }
}

Export-ModuleMember -Function @(
    'Get-WindowsSaveRoot',
    'Get-LocalSaveSlots',
    'Resolve-MainSaveFile',
    'Get-SaveVersionInfo',
    'Test-SaveFolder',
    'Get-SaveManifest',
    'Compare-SaveFolders',
    'Get-NewerSideHint',
    'Get-PCGameVersion',
    'Test-VersionCompatibility',
    'ConvertTo-BridgeVersion'
)
