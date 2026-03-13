Set-StrictMode -Version Latest

function New-BridgeBackup {
    param(
        [Parameter(Mandatory)]
        [string]$SlotName,

        [Parameter(Mandatory)]
        [ValidateSet('PC', 'Phone')]
        [string]$TargetSide,

        [Parameter(Mandatory)]
        [string]$OperationType,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter(Mandatory)]
        [hashtable]$Metadata,

        [switch]$DryRun
    )

    $stamp = Get-BridgeTimestamp
    $slotRoot = Join-Path -Path $BackupRoot -ChildPath $SlotName
    $targetRoot = Join-Path -Path $slotRoot -ChildPath $TargetSide
    $backupPath = Join-Path -Path $targetRoot -ChildPath $stamp
    $contentRoot = Join-Path -Path $backupPath -ChildPath 'content'

    if ($DryRun) {
        return [pscustomobject]@{
            Created = $false
            DryRun = $true
            BackupPath = $backupPath
            MetadataPath = Join-Path -Path $backupPath -ChildPath 'metadata.json'
        }
    }

    Ensure-BridgeDirectory -Path $contentRoot | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $contentRoot -Recurse -Force

    $payload = [ordered]@{
        createdAt = (Get-Date).ToString('o')
        slotName = $SlotName
        targetSide = $TargetSide
        operationType = $OperationType
        sourcePath = $SourcePath
        metadata = $Metadata
    }

    $metadataPath = Join-Path -Path $backupPath -ChildPath 'metadata.json'
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

    return [pscustomobject]@{
        Created = $true
        DryRun = $false
        BackupPath = $backupPath
        MetadataPath = $metadataPath
    }
}

function Get-BridgeBackups {
    param(
        [Parameter(Mandatory)]
        [string]$SlotName,

        [Parameter(Mandatory)]
        [string]$BackupRoot
    )

    $slotRoot = Join-Path -Path $BackupRoot -ChildPath $SlotName
    if (-not (Test-Path -LiteralPath $slotRoot -PathType Container)) {
        return @()
    }

    $backups = @()

    foreach ($targetSide in @('PC', 'Phone')) {
        $sideRoot = Join-Path -Path $slotRoot -ChildPath $targetSide
        if (-not (Test-Path -LiteralPath $sideRoot -PathType Container)) {
            continue
        }

        foreach ($backupDir in (Get-ChildItem -LiteralPath $sideRoot -Directory | Sort-Object -Property Name -Descending)) {
            $metadataPath = Join-Path -Path $backupDir.FullName -ChildPath 'metadata.json'
            $metadata = $null
            if (Test-Path -LiteralPath $metadataPath) {
                $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            }

            $contentRoot = Join-Path -Path $backupDir.FullName -ChildPath 'content'
            $contentPath = Get-ChildItem -LiteralPath $contentRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

            $backups += [pscustomobject]@{
                Id = $backupDir.Name
                SlotName = $SlotName
                TargetSide = $targetSide
                BackupPath = $backupDir.FullName
                ContentPath = $contentPath
                MetadataPath = $metadataPath
                Metadata = $metadata
            }
        }
    }

    return @($backups | Sort-Object -Property Id -Descending)
}

function Invoke-BridgeBackupPrune {
    param(
        [Parameter(Mandatory)]
        [string]$SlotName,

        [Parameter(Mandatory)]
        [ValidateSet('PC', 'Phone')]
        [string]$TargetSide,

        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter(Mandatory)]
        [int]$RetentionCount,

        [switch]$DryRun
    )

    $sideRoot = Join-Path -Path (Join-Path -Path $BackupRoot -ChildPath $SlotName) -ChildPath $TargetSide
    if (-not (Test-Path -LiteralPath $sideRoot -PathType Container)) {
        return @()
    }

    $directories = Get-ChildItem -LiteralPath $sideRoot -Directory | Sort-Object -Property Name -Descending
    $toRemove = @($directories | Select-Object -Skip $RetentionCount)

    if (-not $DryRun) {
        foreach ($directory in $toRemove) {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        }
    }

    return $toRemove
}

Export-ModuleMember -Function @(
    'New-BridgeBackup',
    'Get-BridgeBackups',
    'Invoke-BridgeBackupPrune'
)
