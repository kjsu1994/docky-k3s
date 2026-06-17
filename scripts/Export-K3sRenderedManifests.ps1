param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$Root = "C:\K3s",
    [string]$OutputRoot = "C:\K3s\runtime\rendered",
    [ValidateSet("auto", "cpu", "gpu")]
    [string]$OllamaGpuMode = "cpu",
    [switch]$UseOllamaRuntimeClass,
    [switch]$IncludeCloudflared,
    [switch]$IncludeMinioBootstrapJob
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$renderRoot = [System.IO.Path]::GetFullPath("C:\K3s\runtime\rendered").TrimEnd('\')
if (-not ($resolvedOutputRoot.Equals($renderRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputRoot.StartsWith($renderRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputRoot must stay under C:\K3s\runtime\rendered: $resolvedOutputRoot"
}
$outputDir = Join-Path $resolvedOutputRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$resolvedOutputDir = (Resolve-Path $outputDir).Path
if (-not $resolvedOutputDir.StartsWith($renderRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Output directory must stay under C:\K3s\runtime\rendered: $resolvedOutputDir"
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
        [string]$OllamaGpuMode,
        [bool]$UseRuntimeClass = $false
    )

    $cpuRoot = switch ($Environment) {
        "staging" { Join-Path $Root "overlays\staging" }
        "docker-desktop" { Join-Path $Root "overlays\docker-desktop" }
        default { Join-Path $Root "manifests" }
    }

    if ($OllamaGpuMode -eq "cpu") {
        Write-Host "Ollama GPU mode: cpu. Rendering CPU manifest root: $cpuRoot"
        return $cpuRoot
    }

    $gpuOverlayName = if ($UseRuntimeClass) { "$Environment-ollama-gpu-runtimeclass" } else { "$Environment-ollama-gpu" }
    $gpuRoot = Join-Path $Root "overlays\$gpuOverlayName"
    if ($OllamaGpuMode -eq "gpu") {
        Write-Host "Ollama GPU mode: gpu. Rendering GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    if (Test-OllamaGpuResourceAvailable) {
        Write-Host "Ollama GPU mode: auto detected nvidia.com/gpu. Rendering GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    Write-Host "Ollama GPU mode: auto found no allocatable nvidia.com/gpu. Rendering CPU manifest root: $cpuRoot"
    return $cpuRoot
}

$appRoot = Resolve-AppRoot -Environment $Environment -Root $Root -OllamaGpuMode $OllamaGpuMode -UseRuntimeClass ([bool]$UseOllamaRuntimeClass)

function Export-KustomizeRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestRoot,
        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    if (-not (Test-Path $ManifestRoot)) {
        throw "Manifest root not found: $ManifestRoot"
    }

    $rendered = & kubectl kustomize $ManifestRoot
    if ($LASTEXITCODE -ne 0 -or -not $rendered) {
        throw "kubectl kustomize failed or produced no output: $ManifestRoot"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputFile, ($rendered -join [Environment]::NewLine) + [Environment]::NewLine, $utf8NoBom)
}

Export-KustomizeRoot -ManifestRoot (Join-Path $Root "ingress-nginx") -OutputFile (Join-Path $resolvedOutputDir "ingress-nginx.yml")
if ($OllamaGpuMode -ne "cpu") {
    Export-KustomizeRoot -ManifestRoot (Join-Path $Root "nvidia-device-plugin") -OutputFile (Join-Path $resolvedOutputDir "nvidia-device-plugin.yml")
}
Export-KustomizeRoot -ManifestRoot $appRoot -OutputFile (Join-Path $resolvedOutputDir "app-$Environment.yml")

if ($IncludeCloudflared) {
    Export-KustomizeRoot -ManifestRoot (Join-Path $Root "cloudflared") -OutputFile (Join-Path $resolvedOutputDir "cloudflared.yml")
}

if ($IncludeMinioBootstrapJob) {
    $source = Join-Path $Root "jobs\minio-bootstrap-job.yml"
    if (-not (Test-Path $source)) {
        throw "MinIO bootstrap job not found: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $resolvedOutputDir "minio-bootstrap-job.yml") -Force
}

$metadata = [ordered]@{
    environment = $Environment
    includeCloudflared = [bool]$IncludeCloudflared
    includeMinioBootstrapJob = [bool]$IncludeMinioBootstrapJob
    ollamaGpuMode = $OllamaGpuMode
    useOllamaRuntimeClass = [bool]$UseOllamaRuntimeClass
    root = (Resolve-Path $Root).Path
    appRoot = (Resolve-Path $appRoot).Path
    outputDir = $resolvedOutputDir
    createdAt = (Get-Date).ToString("o")
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resolvedOutputDir "metadata.json") -Encoding UTF8

Write-Host "Rendered manifest snapshot written: $resolvedOutputDir"
