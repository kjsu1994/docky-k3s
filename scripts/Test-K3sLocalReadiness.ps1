param(
    [string]$Root = "C:\K3s",
    [switch]$RequireRuntimeSecrets
)

$ErrorActionPreference = "Stop"

$requiredFiles = @(
    "pending-inputs.ko.md",
    "templates\cutover-runbook.ko.md",
    "templates\rollback-runbook.ko.md",
    "templates\cutover-input-report.ko.md",
    "templates\explan.ko.md",
    "ingress-nginx\kustomization.yml",
    "ingress-nginx\namespace.yml",
    "ingress-nginx\upstream\deploy-v1.15.1.yml",
    "manifests\kustomization.yml",
    "overlays\staging\kustomization.yml",
    "overlays\docker-desktop\kustomization.yml",
    "cloudflared\kustomization.yml",
    "scripts\New-DockySecretFromEnv.ps1",
    "scripts\New-GhcrImagePullSecret.ps1",
    "scripts\Import-K3sKubeconfig.ps1",
    "scripts\Export-K3sRenderedManifests.ps1",
    "scripts\Test-K3sRenderedSnapshots.ps1",
    "scripts\Collect-K3sDiagnostics.ps1",
    "scripts\Get-K3sMigrationStatus.ps1",
    "scripts\Set-K3sImageTags.ps1",
    "scripts\New-K3sCutoverRunbook.ps1",
    "scripts\New-K3sRollbackRunbook.ps1",
    "scripts\Test-K3sComposeBoundary.ps1",
    "scripts\Test-K3sRunbooks.ps1",
    "scripts\Invoke-K3sImagePipeline.ps1",
    "scripts\Invoke-K3sPostApplyValidation.ps1",
    "scripts\Test-K3sFrontendStaticSource.ps1",
    "scripts\Test-K3sImageRuntime.ps1",
    "scripts\Test-K3sReleaseImages.ps1",
    "scripts\Test-K3sSecretSources.ps1",
    "scripts\Test-K3sCutoverInputs.ps1",
    "scripts\Test-K3sInClusterConnectivity.ps1",
    "scripts\Test-K3sImagePolicy.ps1",
    "scripts\Test-K3sExternalDependencies.ps1",
    "scripts\Test-K3sComposeParity.ps1",
    "scripts\Test-K3sHostPrereqs.ps1",
    "scripts\Test-K3sClusterPrereqs.ps1",
    "scripts\Test-K3sServerDryRun.ps1",
    "scripts\Test-K3sEnvBoundaries.ps1",
    "scripts\Test-K3sCutoverGate.ps1",
    "scripts\Test-K3sCompletionGate.ps1",
    "scripts\Test-K3sDockerDesktopReadiness.ps1",
    "scripts\Invoke-K3sComposeBackup.ps1",
    "scripts\Test-K3sBackupSet.ps1",
    "scripts\Test-K3sBackupPreflight.ps1",
    "scripts\Test-K3sStoragePlan.ps1",
    "scripts\Invoke-K3sOracleSqlfileRehearsal.ps1",
    "scripts\Invoke-K3sOracleRestore.ps1",
    "scripts\Invoke-K3sMinioRestore.ps1",
    "scripts\Invoke-K3sRedisRestore.ps1",
    "scripts\Test-K3sRestoredData.ps1",
    "scripts\Test-K3sSecretManifests.ps1",
    "scripts\Test-K3sHttpSmoke.ps1",
    "scripts\New-K3sExplanation.ps1"
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path $path)) {
        throw "Required file missing: $path"
    }
}

$disallowedYamlExtension = ".ya" + "ml"
$yamlFiles = Get-ChildItem -Path $Root -Recurse -File | Where-Object { $_.Extension -eq $disallowedYamlExtension }
if ($yamlFiles) {
    throw "Use .yml extension only. Found: $($yamlFiles.FullName -join ', ')"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Manifest render check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sComposeBoundary.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "K3s/Compose boundary check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sEnvBoundaries.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Environment boundary check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sImagePolicy.ps1") -IncludeCloudflared -IncludeJobs -IncludeBuildFiles -IncludeScripts
if ($LASTEXITCODE -ne 0) {
    throw "Image policy check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sRunbooks.ps1") -RequireGeneratedRunbook -RequireRollbackRunbook
if ($LASTEXITCODE -ne 0) {
    throw "Runbook check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sSecretSources.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Secret source check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sBackupPreflight.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Backup preflight check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sCutoverInputs.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Cutover input check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sRenderedSnapshots.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Rendered snapshot check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sExternalDependencies.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "External dependency check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sComposeParity.ps1") -FailOnMismatch
if ($LASTEXITCODE -ne 0) {
    throw "Compose parity check failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sStoragePlan.ps1") -FailOnInsufficient
if ($LASTEXITCODE -ne 0) {
    throw "Storage plan check failed."
}

if ($RequireRuntimeSecrets) {
    foreach ($relative in @("runtime\docky-secret.yml", "runtime\ghcr-pull-secret.yml")) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path $path)) {
            throw "Runtime secret manifest missing: $path"
        }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1") -FailOnPlaceholderImages
    if ($LASTEXITCODE -ne 0) {
        throw "Placeholder image gate failed."
    }
}

Write-Host "Local K3s readiness checks passed."
