param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$Root = "C:\K3s",
    [string]$DockySecretPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$GhcrSecretPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [string]$BackupPath,
    [string]$Kubeconfig,
    [switch]$RequireBackupSet,
    [switch]$SkipKubernetesContext,
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$RequireRegistryImageAvailability
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sRunbooks.ps1") `
    -Environment $Environment `
    -RequireGeneratedRunbook `
    -RequireRollbackRunbook
if ($LASTEXITCODE -ne 0) {
    throw "Runbook gate failed."
}

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

if (-not $SkipKubernetesContext) {
    $hostArgs = @(
        "-RequireKubernetesContext",
        "-SkipDocker"
    )
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $hostArgs += @("-Kubeconfig", $Kubeconfig)
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sHostPrereqs.ps1") @hostArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Kubernetes host prerequisite gate failed."
    }

    $clusterArgs = @(
        "-Environment", $Environment
    )
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $clusterArgs += @("-Kubeconfig", $Kubeconfig)
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sClusterPrereqs.ps1") @clusterArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Kubernetes cluster prerequisite gate failed."
    }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1") `
    -Environment $Environment `
    -FailOnPlaceholderImages
if ($LASTEXITCODE -ne 0) {
    throw "Manifest placeholder gate failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sEnvBoundaries.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Environment boundary gate failed."
}

$imagePolicyArgs = @("-FailOnMutableTags")
if ($IncludeCloudflared) {
    $imagePolicyArgs += "-IncludeCloudflared"
}
if ($BootstrapMinio) {
    $imagePolicyArgs += "-IncludeJobs"
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sImagePolicy.ps1") @imagePolicyArgs
if ($LASTEXITCODE -ne 0) {
    throw "Image policy gate failed."
}

$releaseImageArgs = @(
    "-Environment", $Environment,
    "-Root", $Root
)
if ($RequireRegistryImageAvailability) {
    $releaseImageArgs += "-RequireRegistryAvailability"
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sReleaseImages.ps1") @releaseImageArgs
if ($LASTEXITCODE -ne 0) {
    throw "Release image gate failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sExternalDependencies.ps1") `
    -Environment $Environment `
    -FailOnUnresolved
if ($LASTEXITCODE -ne 0) {
    throw "External dependency gate failed."
}

$secretArgs = @(
    "-DockySecretPath", $DockySecretPath,
    "-GhcrSecretPath", $GhcrSecretPath
)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sSecretManifests.ps1") @secretArgs
if ($LASTEXITCODE -ne 0) {
    throw "Runtime secret gate failed."
}

$backupRequired = $RequireBackupSet -or $Environment -eq "production"
if ($backupRequired) {
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw "BackupPath is required for $Environment cutover gate."
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sBackupSet.ps1") `
        -BackupPath $BackupPath `
        -RequireOracle `
        -RequireRedis `
        -RequireMinio `
        -RequireMinioContent
    if ($LASTEXITCODE -ne 0) {
        throw "Backup set gate failed."
    }
}

Write-Host "K3s cutover gate passed for $Environment."
