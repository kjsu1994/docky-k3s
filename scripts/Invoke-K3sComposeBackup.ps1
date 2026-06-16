param(
    [string]$ComposeRoot = "C:\compose",
    [string]$BackupRoot = "C:\K3s\backups",
    [switch]$SkipOracle,
    [switch]$SkipRedis,
    [switch]$SkipMinioContent,
    [switch]$ConfirmBackup
)

$ErrorActionPreference = "Stop"

$confirmEnvName = "K3S_COMPOSE_BACKUP_CONFIRM"
$confirmEnvValue = "backup-to-k3s"

if (-not ($ConfirmBackup -or [Environment]::GetEnvironmentVariable($confirmEnvName) -eq $confirmEnvValue)) {
    throw "Refusing to run live backup. Pass -ConfirmBackup or set $confirmEnvName=$confirmEnvValue."
}

$resolvedComposeRoot = (Resolve-Path $ComposeRoot).Path
$resolvedBackupRoot = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')

if (-not $resolvedComposeRoot.Equals("C:\compose", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ComposeRoot must remain C:\compose for this migration wrapper: $resolvedComposeRoot"
}
if (-not ($resolvedBackupRoot.Equals("C:\K3s\backups", [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedBackupRoot.StartsWith("C:\K3s\backups\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "BackupRoot must stay under C:\K3s\backups: $resolvedBackupRoot"
}
if (-not (Test-Path $resolvedBackupRoot)) {
    New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null
}

$backupScript = Join-Path $resolvedComposeRoot "scripts\backup-live.ps1"
if (-not (Test-Path $backupScript)) {
    throw "Compose backup script not found: $backupScript"
}

$argsList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $backupScript,
    "-ComposeRoot", $resolvedComposeRoot,
    "-BackupRoot", $resolvedBackupRoot
)
if ($SkipOracle) { $argsList += "-SkipOracle" }
if ($SkipRedis) { $argsList += "-SkipRedis" }
if ($SkipMinioContent) { $argsList += "-SkipMinioContent" }

Write-Host "Running read-source backup from $resolvedComposeRoot to $resolvedBackupRoot"
& powershell.exe @argsList
if ($LASTEXITCODE -ne 0) {
    throw "K3s backup wrapper failed with exit code $LASTEXITCODE"
}
