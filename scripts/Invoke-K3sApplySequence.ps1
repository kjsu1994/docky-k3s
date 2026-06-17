param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$DockySecretPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$GhcrSecretPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [string]$BackupPath,
    [string]$Kubeconfig,
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$SkipRenderSnapshot,
    [switch]$SkipServerDryRun,
    [ValidateSet("auto", "cpu", "gpu")]
    [string]$OllamaGpuMode = "auto",
    [switch]$ConfirmApply
)

$ErrorActionPreference = "Stop"

$confirmEnvName = "K3S_APPLY_CONFIRM"
$confirmEnvValue = "apply-k3s"
if (-not ($ConfirmApply -or [Environment]::GetEnvironmentVariable($confirmEnvName) -eq $confirmEnvValue)) {
    throw "Refusing to apply manifests. Pass -ConfirmApply or set $confirmEnvName=$confirmEnvValue."
}

$root = "C:\K3s"
if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

function Test-OllamaGpuResourceAvailable {
    $nodesJson = (& kubectl get nodes -o json 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $nodesJson) {
        return $false
    }

    $nodes = ($nodesJson -join [Environment]::NewLine) | ConvertFrom-Json
    foreach ($node in $nodes.items) {
        $gpu = $node.status.allocatable.'nvidia.com/gpu'
        $gpuCount = 0
        if (-not [string]::IsNullOrWhiteSpace($gpu) -and [int]::TryParse([string]$gpu, [ref]$gpuCount) -and $gpuCount -gt 0) {
            return $true
        }
    }
    return $false
}

function Resolve-AppRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$OllamaGpuMode
    )

    $cpuRoot = switch ($Environment) {
        "staging" { Join-Path $Root "overlays\staging" }
        "docker-desktop" { Join-Path $Root "overlays\docker-desktop" }
        default { Join-Path $Root "manifests" }
    }

    if ($OllamaGpuMode -eq "cpu") {
        Write-Host "Ollama GPU mode: cpu. Using CPU manifest root: $cpuRoot"
        return $cpuRoot
    }

    $gpuRoot = Join-Path $Root "overlays\$Environment-ollama-gpu"
    if ($OllamaGpuMode -eq "gpu") {
        Write-Host "Ollama GPU mode: gpu. Using GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    if (Test-OllamaGpuResourceAvailable) {
        Write-Host "Ollama GPU mode: auto detected nvidia.com/gpu. Using GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    Write-Host "Ollama GPU mode: auto found no allocatable nvidia.com/gpu. Falling back to CPU manifest root: $cpuRoot"
    return $cpuRoot
}

$appRoot = Resolve-AppRoot -Environment $Environment -Root $root -OllamaGpuMode $OllamaGpuMode

$gateArgs = @(
    "-Environment", $Environment,
    "-DockySecretPath", $DockySecretPath,
    "-GhcrSecretPath", $GhcrSecretPath
)
if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    $gateArgs += @("-BackupPath", $BackupPath)
}
if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    $gateArgs += @("-Kubeconfig", $Kubeconfig)
}
if ($IncludeCloudflared) {
    $gateArgs += "-IncludeCloudflared"
}
if ($BootstrapMinio) {
    $gateArgs += "-BootstrapMinio"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sCutoverGate.ps1") @gateArgs
if ($LASTEXITCODE -ne 0) {
    throw "Cutover gate failed."
}

if (-not $SkipRenderSnapshot) {
    $renderArgs = @(
        "-Environment", $Environment,
        "-OllamaGpuMode", $OllamaGpuMode
    )
    if ($IncludeCloudflared) {
        $renderArgs += "-IncludeCloudflared"
    }
    if ($BootstrapMinio) {
        $renderArgs += "-IncludeMinioBootstrapJob"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Export-K3sRenderedManifests.ps1") @renderArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to export rendered manifest snapshot."
    }
}

kubectl apply -f (Join-Path $root "manifests\namespace.yml")
if ($LASTEXITCODE -ne 0) { throw "Failed to apply namespace." }

kubectl apply -f (Join-Path $root "ingress-nginx\namespace.yml")
if ($LASTEXITCODE -ne 0) { throw "Failed to apply ingress-nginx namespace." }

if (-not $SkipServerDryRun) {
    $serverDryRunArgs = @(
        "-Environment", $Environment,
        "-DockySecretPath", $DockySecretPath,
        "-GhcrSecretPath", $GhcrSecretPath,
        "-OllamaGpuMode", $OllamaGpuMode
    )
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $serverDryRunArgs += @("-Kubeconfig", $Kubeconfig)
    }
    if ($IncludeCloudflared) {
        $serverDryRunArgs += "-IncludeCloudflared"
    }
    if ($BootstrapMinio) {
        $serverDryRunArgs += "-BootstrapMinio"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sServerDryRun.ps1") @serverDryRunArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Server dry-run failed."
    }
}

kubectl apply -f $DockySecretPath
if ($LASTEXITCODE -ne 0) { throw "Failed to apply docky runtime secret: $DockySecretPath" }

kubectl apply -f $GhcrSecretPath
if ($LASTEXITCODE -ne 0) { throw "Failed to apply GHCR image pull secret: $GhcrSecretPath" }

kubectl apply -k (Join-Path $root "ingress-nginx")
if ($LASTEXITCODE -ne 0) { throw "Failed to apply ingress-nginx." }

kubectl apply -k $appRoot
if ($LASTEXITCODE -ne 0) { throw "Failed to apply app manifests: $appRoot" }

if ($BootstrapMinio) {
    kubectl apply -f (Join-Path $root "jobs\minio-bootstrap-job.yml")
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply MinIO bootstrap job." }
}

if ($IncludeCloudflared) {
    kubectl apply -k (Join-Path $root "cloudflared")
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply cloudflared." }
}

Write-Host "Apply sequence submitted for $Environment."
