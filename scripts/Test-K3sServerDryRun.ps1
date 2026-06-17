param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$Root = "C:\K3s",
    [string]$DockySecretPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$GhcrSecretPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [string]$Kubeconfig,
    [ValidateSet("auto", "cpu", "gpu")]
    [string]$OllamaGpuMode = "auto",
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$SkipIngress
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
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
        Write-Host "Ollama GPU mode: cpu. Dry-running CPU manifest root: $cpuRoot"
        return $cpuRoot
    }

    $gpuRoot = Join-Path $Root "overlays\$Environment-ollama-gpu"
    if ($OllamaGpuMode -eq "gpu") {
        Write-Host "Ollama GPU mode: gpu. Dry-running GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    if (Test-OllamaGpuResourceAvailable) {
        Write-Host "Ollama GPU mode: auto detected nvidia.com/gpu. Dry-running GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    Write-Host "Ollama GPU mode: auto found no allocatable nvidia.com/gpu. Dry-running CPU manifest root: $cpuRoot"
    return $cpuRoot
}

$appRoot = Resolve-AppRoot -Environment $Environment -Root $Root -OllamaGpuMode $OllamaGpuMode

function Invoke-ServerDryRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string[]]$KubectlArgs
    )

    Write-Host "Server dry-run: $Description"
    & kubectl @KubectlArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Server dry-run failed: $Description"
    }
}

function Assert-NamespaceExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    & kubectl get namespace $Name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Namespace must exist before namespaced server dry-run: $Name"
    }
}

Invoke-ServerDryRun -Description "docky namespace" -KubectlArgs @(
    "apply", "--dry-run=server", "-f", (Join-Path $Root "manifests\namespace.yml")
)
Invoke-ServerDryRun -Description "ingress-nginx namespace" -KubectlArgs @(
    "apply", "--dry-run=server", "-f", (Join-Path $Root "ingress-nginx\namespace.yml")
)

Assert-NamespaceExists -Name "docky"
if (-not $SkipIngress) {
    Assert-NamespaceExists -Name "ingress-nginx"
}

Invoke-ServerDryRun -Description "docky runtime secret" -KubectlArgs @(
    "apply", "--dry-run=server", "-f", $DockySecretPath
)

if ($Environment -ne "docker-desktop") {
    Invoke-ServerDryRun -Description "GHCR image pull secret" -KubectlArgs @(
        "apply", "--dry-run=server", "-f", $GhcrSecretPath
    )
}

if (-not $SkipIngress) {
    Invoke-ServerDryRun -Description "ingress-nginx" -KubectlArgs @(
        "apply", "--dry-run=server", "-k", (Join-Path $Root "ingress-nginx")
    )
}

Invoke-ServerDryRun -Description "docky app manifests" -KubectlArgs @(
    "apply", "--dry-run=server", "-k", $appRoot
)

if ($BootstrapMinio) {
    Invoke-ServerDryRun -Description "MinIO bootstrap job" -KubectlArgs @(
        "apply", "--dry-run=server", "-f", (Join-Path $Root "jobs\minio-bootstrap-job.yml")
    )
}

if ($IncludeCloudflared) {
    Invoke-ServerDryRun -Description "cloudflared" -KubectlArgs @(
        "apply", "--dry-run=server", "-k", (Join-Path $Root "cloudflared")
    )
}

Write-Host "K3s server dry-run checks passed for $Environment."
