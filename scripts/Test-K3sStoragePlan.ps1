param(
    [string]$Root = "C:\K3s",
    [string]$BackupPath,
    [string]$ComposeRoot = "C:\compose",
    [switch]$CheckComposeDataSize,
    [switch]$FailOnInsufficient,
    [int]$MinioHeadroomPercent = 20,
    [int]$RedisHeadroomPercent = 100,
    [int]$OracleDumpExpansionFactor = 4
)

$ErrorActionPreference = "Stop"

function Convert-StorageQuantityToBytes {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = $Value.Trim().Trim('"').Trim("'")
    if ($trimmed -notmatch '^([0-9]+)(Ki|Mi|Gi|Ti|K|M|G|T)?$') {
        throw "Unsupported storage quantity: $Value"
    }

    $number = [decimal]$matches[1]
    $unit = $matches[2]
    switch ($unit) {
        "Ki" { return [int64]($number * 1KB) }
        "Mi" { return [int64]($number * 1MB) }
        "Gi" { return [int64]($number * 1GB) }
        "Ti" { return [int64]($number * 1TB) }
        "K" { return [int64]($number * 1000) }
        "M" { return [int64]($number * 1000 * 1000) }
        "G" { return [int64]($number * 1000 * 1000 * 1000) }
        "T" { return [int64]($number * 1000 * 1000 * 1000 * 1000) }
        default { return [int64]$number }
    }
}

function Format-Bytes {
    param([int64]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TiB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GiB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MiB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KiB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DirectorySizeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Add-Finding {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [string]$Name,
        [string]$Status,
        [string]$Detail
    )

    $Target.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$pvcPath = Join-Path $Root "manifests\storage\pvc.yml"
if (-not (Test-Path $pvcPath)) {
    throw "PVC manifest not found: $pvcPath"
}

$pvcMap = @{}
$currentName = $null
$lines = Get-Content -LiteralPath $pvcPath
foreach ($line in $lines) {
    if ($line -match '^\s*name:\s+([A-Za-z0-9._-]+)\s*$') {
        $currentName = $matches[1]
        if (-not $pvcMap.ContainsKey($currentName)) {
            $pvcMap[$currentName] = [ordered]@{
                Storage = $null
                StorageBytes = 0
                AccessModes = New-Object System.Collections.Generic.List[string]
            }
        }
    } elseif ($currentName -and $line -match '^\s*-\s+(ReadWriteOnce|ReadWriteMany|ReadOnlyMany)\s*$') {
        $pvcMap[$currentName].AccessModes.Add($matches[1]) | Out-Null
    } elseif ($currentName -and $line -match '^\s*storage:\s+(.+?)\s*$') {
        $pvcMap[$currentName].Storage = $matches[1].Trim()
        $pvcMap[$currentName].StorageBytes = Convert-StorageQuantityToBytes -Value $pvcMap[$currentName].Storage
    }
}

$findings = New-Object System.Collections.Generic.List[object]
$requiredPvcs = @("oracle-data", "minio-data", "redis-data", "ollama-data")
foreach ($name in $requiredPvcs) {
    if (-not $pvcMap.ContainsKey($name)) {
        Add-Finding -Target $findings -Name $name -Status "FAIL" -Detail "PVC is missing."
        continue
    }
    $entry = $pvcMap[$name]
    if ($entry.StorageBytes -le 0) {
        Add-Finding -Target $findings -Name $name -Status "FAIL" -Detail "PVC storage request is missing."
        continue
    }
    if (-not ($entry.AccessModes -contains "ReadWriteOnce")) {
        Add-Finding -Target $findings -Name $name -Status "FAIL" -Detail "Expected ReadWriteOnce access mode."
        continue
    }
    Add-Finding -Target $findings -Name $name -Status "PASS" -Detail "request=$($entry.Storage) ($(Format-Bytes $entry.StorageBytes)), accessModes=$($entry.AccessModes -join ',')"
}

if ($CheckComposeDataSize) {
    $resolvedComposeRoot = (Resolve-Path $ComposeRoot).Path
    if (-not $resolvedComposeRoot.Equals("C:\compose", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ComposeRoot must remain C:\compose for this migration check: $resolvedComposeRoot"
    }

    $composeMinioPath = Join-Path $resolvedComposeRoot "minio-data"
    if (Test-Path $composeMinioPath) {
        $minioBytes = Get-DirectorySizeBytes -Path $composeMinioPath
        $requiredBytes = [int64]($minioBytes * (1 + ($MinioHeadroomPercent / 100)))
        $availableBytes = [int64]$pvcMap["minio-data"].StorageBytes
        $status = if ($availableBytes -ge $requiredBytes) { "PASS" } else { "FAIL" }
        Add-Finding -Target $findings -Name "compose-minio-size" -Status $status -Detail "source=$(Format-Bytes $minioBytes), requiredWithHeadroom=$(Format-Bytes $requiredBytes), pvc=$(Format-Bytes $availableBytes)"
    } else {
        Add-Finding -Target $findings -Name "compose-minio-size" -Status "WARN" -Detail "Compose MinIO source path not found: $composeMinioPath"
    }
}

if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    if (-not (Test-Path $BackupPath)) {
        throw "Backup path not found: $BackupPath"
    }
    $resolvedBackupRoot = (Resolve-Path (Join-Path $Root "backups")).Path
    $resolvedBackupPath = (Resolve-Path $BackupPath).Path
    if (-not $resolvedBackupPath.StartsWith($resolvedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "BackupPath must stay under ${resolvedBackupRoot}: $resolvedBackupPath"
    }

    $minioCopyManifest = Join-Path $resolvedBackupPath "minio\minio-copy-manifest.json"
    if (Test-Path $minioCopyManifest) {
        $manifest = Get-Content -Raw -LiteralPath $minioCopyManifest | ConvertFrom-Json
        $minioBytes = [int64]$manifest.totalBytes
        $requiredBytes = [int64]($minioBytes * (1 + ($MinioHeadroomPercent / 100)))
        $availableBytes = [int64]$pvcMap["minio-data"].StorageBytes
        $status = if ($availableBytes -ge $requiredBytes) { "PASS" } else { "FAIL" }
        Add-Finding -Target $findings -Name "backup-minio-size" -Status $status -Detail "backup=$(Format-Bytes $minioBytes), requiredWithHeadroom=$(Format-Bytes $requiredBytes), pvc=$(Format-Bytes $availableBytes)"
    }

    $redisRdb = Get-ChildItem -LiteralPath (Join-Path $resolvedBackupPath "redis") -File -Filter "*.rdb" -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 1
    if ($redisRdb) {
        $redisBytes = [int64]$redisRdb.Length
        $requiredBytes = [int64]($redisBytes * (1 + ($RedisHeadroomPercent / 100)))
        $availableBytes = [int64]$pvcMap["redis-data"].StorageBytes
        $status = if ($availableBytes -ge $requiredBytes) { "PASS" } else { "FAIL" }
        Add-Finding -Target $findings -Name "backup-redis-size" -Status $status -Detail "rdb=$(Format-Bytes $redisBytes), requiredWithHeadroom=$(Format-Bytes $requiredBytes), pvc=$(Format-Bytes $availableBytes)"
    }

    $oracleDump = Get-ChildItem -LiteralPath (Join-Path $resolvedBackupPath "oracle") -File -Filter "*.dmp" -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 1
    if ($oracleDump) {
        $dumpBytes = [int64]$oracleDump.Length
        $requiredBytes = [int64]($dumpBytes * $OracleDumpExpansionFactor)
        $availableBytes = [int64]$pvcMap["oracle-data"].StorageBytes
        $status = if ($availableBytes -ge $requiredBytes) { "PASS" } else { "FAIL" }
        Add-Finding -Target $findings -Name "backup-oracle-estimate" -Status $status -Detail "dump=$(Format-Bytes $dumpBytes), estimatedRequired=$(Format-Bytes $requiredBytes), pvc=$(Format-Bytes $availableBytes)"
    }
}

$findings | Format-Table -AutoSize

$failures = @($findings | Where-Object { $_.Status -eq "FAIL" })
if ($failures.Count -gt 0 -and $FailOnInsufficient) {
    throw "K3s storage plan has insufficient or invalid capacity."
}

if ($failures.Count -gt 0) {
    Write-Warning "K3s storage plan has findings. Pass -FailOnInsufficient to fail on them."
} else {
    Write-Host "K3s storage plan checks passed."
}
