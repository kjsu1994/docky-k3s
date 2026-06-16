param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$Root = "C:\K3s",
    [string]$OutputRoot = "C:\K3s\runtime\rendered",
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

$appRoot = switch ($Environment) {
    "staging" { Join-Path $Root "overlays\staging" }
    "docker-desktop" { Join-Path $Root "overlays\docker-desktop" }
    default { Join-Path $Root "manifests" }
}

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
    root = (Resolve-Path $Root).Path
    appRoot = (Resolve-Path $appRoot).Path
    outputDir = $resolvedOutputDir
    createdAt = (Get-Date).ToString("o")
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resolvedOutputDir "metadata.json") -Encoding UTF8

Write-Host "Rendered manifest snapshot written: $resolvedOutputDir"
