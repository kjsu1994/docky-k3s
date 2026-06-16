param(
    [string]$BackupPath,
    [string]$BackupRoot = "C:\K3s\backups",
    [switch]$RequireOracle,
    [switch]$RequireRedis,
    [switch]$RequireMinio,
    [switch]$RequireMinioContent
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BackupRoot)) {
    throw "Backup root not found: $BackupRoot"
}

$resolvedBackupRoot = (Resolve-Path $BackupRoot).Path
if (-not $resolvedBackupRoot.StartsWith("C:\K3s\backups", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupRoot must stay under C:\K3s\backups: $resolvedBackupRoot"
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $candidate = Get-ChildItem -LiteralPath $resolvedBackupRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "backup-summary.json") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No backup sessions found under $resolvedBackupRoot."
    }
    $BackupPath = $candidate.FullName
}

if (-not (Test-Path $BackupPath)) {
    throw "Backup path not found: $BackupPath"
}

$resolvedBackupPath = (Resolve-Path $BackupPath).Path
if (-not $resolvedBackupPath.StartsWith($resolvedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupPath must stay under ${resolvedBackupRoot}: $resolvedBackupPath"
}

function Assert-NonEmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path $Path)) {
        throw "$Description not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        throw "$Description is empty: $Path"
    }
}

function Assert-AtLeastOneNonEmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [string]$Filter,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path $Directory)) {
        throw "$Description directory not found: $Directory"
    }
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter $Filter)
    if ($files.Count -eq 0) {
        throw "$Description not found in ${Directory}: $Filter"
    }
    foreach ($file in $files) {
        if ($file.Length -gt 0) {
            return
        }
    }
    throw "$Description files are empty in ${Directory}: $Filter"
}

$summaryPath = Join-Path $resolvedBackupPath "backup-summary.json"
Assert-NonEmptyFile -Path $summaryPath -Description "Backup summary"
$summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json

$envHashPath = Join-Path $resolvedBackupPath "config\env.sha256.json"
Assert-NonEmptyFile -Path $envHashPath -Description "Compose env SHA256 summary"

$shouldCheckOracle = $RequireOracle -or [bool]$summary.oracle
$shouldCheckRedis = $RequireRedis -or [bool]$summary.redis
$shouldCheckMinio = $RequireMinio -or [bool]$summary.minio
$shouldCheckMinioContent = $RequireMinioContent -or [bool]$summary.minioContentCopied

if ($shouldCheckOracle) {
    $oracleDir = Join-Path $resolvedBackupPath "oracle"
    Assert-AtLeastOneNonEmptyFile -Directory $oracleDir -Filter "*.dmp" -Description "Oracle dump"
    Assert-AtLeastOneNonEmptyFile -Directory $oracleDir -Filter "*-expdp.log" -Description "Oracle export log"
    Assert-AtLeastOneNonEmptyFile -Directory $oracleDir -Filter "*-restore-rehearsal.sql" -Description "Oracle SQLFILE rehearsal output"
    Assert-AtLeastOneNonEmptyFile -Directory $oracleDir -Filter "*-impdp-sqlfile.log" -Description "Oracle SQLFILE rehearsal log"
}

if ($shouldCheckRedis) {
    $redisDir = Join-Path $resolvedBackupPath "redis"
    Assert-AtLeastOneNonEmptyFile -Directory $redisDir -Filter "*.rdb" -Description "Redis RDB"
    Assert-NonEmptyFile -Path (Join-Path $redisDir "redis-dbsize.txt") -Description "Redis DB size summary"
}

if ($shouldCheckMinio) {
    $minioDir = Join-Path $resolvedBackupPath "minio"
    Assert-NonEmptyFile -Path (Join-Path $minioDir "minio-manifest.json") -Description "MinIO source manifest"
    if ($shouldCheckMinioContent) {
        Assert-NonEmptyFile -Path (Join-Path $minioDir "minio-copy-manifest.json") -Description "MinIO copied-content manifest"
        $minioData = Join-Path $minioDir "minio-data"
        if (-not (Test-Path $minioData)) {
            throw "MinIO copied-content directory not found: $minioData"
        }
    }
}

Write-Host "Backup set checks passed: $resolvedBackupPath"
