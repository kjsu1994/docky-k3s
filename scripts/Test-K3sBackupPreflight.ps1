param(
    [string]$ComposeRoot = "C:\compose",
    [string]$BackupRoot = "C:\K3s\backups",
    [string]$WrapperPath = "C:\K3s\scripts\Invoke-K3sComposeBackup.ps1",
    [switch]$RequireDocker,
    [switch]$RequireComposeContainers,
    [switch]$RequireBackupRoot
)

$ErrorActionPreference = "Stop"

function Assert-PathUnder {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if (-not ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "${Message}: $candidateFull"
    }
    return $candidateFull
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if (-not $Text.Contains($Needle)) {
        throw "$Context is missing required safety text: $Needle"
    }
}

if (-not (Test-Path $ComposeRoot)) {
    throw "ComposeRoot not found: $ComposeRoot"
}
$resolvedComposeRoot = (Resolve-Path $ComposeRoot).Path
if (-not $resolvedComposeRoot.Equals("C:\compose", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ComposeRoot must remain C:\compose: $resolvedComposeRoot"
}

$resolvedBackupRoot = Assert-PathUnder -Candidate $BackupRoot -AllowedRoot "C:\K3s\backups" -Message "BackupRoot must stay under C:\K3s\backups"
if ($RequireBackupRoot -and -not (Test-Path $resolvedBackupRoot)) {
    throw "BackupRoot is required but not found: $resolvedBackupRoot"
}

if (-not (Test-Path $WrapperPath)) {
    throw "K3s backup wrapper not found: $WrapperPath"
}
$resolvedWrapperPath = (Resolve-Path $WrapperPath).Path
$wrapperText = [System.IO.File]::ReadAllText($resolvedWrapperPath, [System.Text.Encoding]::UTF8)
Assert-Contains -Text $wrapperText -Needle 'K3S_COMPOSE_BACKUP_CONFIRM' -Context $resolvedWrapperPath
Assert-Contains -Text $wrapperText -Needle 'ConfirmBackup' -Context $resolvedWrapperPath
Assert-Contains -Text $wrapperText -Needle 'ComposeRoot must remain C:\compose' -Context $resolvedWrapperPath
Assert-Contains -Text $wrapperText -Needle 'BackupRoot must stay under C:\K3s\backups' -Context $resolvedWrapperPath
Assert-Contains -Text $wrapperText -Needle '"-BackupRoot", $resolvedBackupRoot' -Context $resolvedWrapperPath

$backupScript = Join-Path $resolvedComposeRoot "scripts\backup-live.ps1"
if (-not (Test-Path $backupScript)) {
    throw "Compose backup script not found: $backupScript"
}
$backupScriptText = [System.IO.File]::ReadAllText($backupScript, [System.Text.Encoding]::UTF8)
Assert-Contains -Text $backupScriptText -Needle '[string]$BackupRoot' -Context $backupScript
Assert-Contains -Text $backupScriptText -Needle '$sessionDir = Join-Path $BackupRoot $timestamp' -Context $backupScript
Assert-Contains -Text $backupScriptText -Needle 'IncludePlainEnv' -Context $backupScript

foreach ($requiredPath in @(
    (Join-Path $resolvedComposeRoot ".env"),
    (Join-Path $resolvedComposeRoot "docker-compose.yml"),
    (Join-Path $resolvedComposeRoot "minio-data")
)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required Compose backup source missing: $requiredPath"
    }
}

if ($RequireDocker -or $RequireComposeContainers) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        throw "docker not found on PATH."
    }
    docker version --format "{{.Server.Version}}" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "docker daemon is not reachable."
    }
}

if ($RequireComposeContainers) {
    $containerNames = @(docker ps --format "{{.Names}}")
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list Docker containers."
    }
    foreach ($container in @("oracle", "redis")) {
        if ($containerNames -notcontains $container) {
            throw "Required Compose container is not running: $container"
        }
    }
}

Write-Host "K3s backup preflight checks passed."
Write-Host "Compose backup script: $backupScript"
Write-Host "K3s backup root: $resolvedBackupRoot"
