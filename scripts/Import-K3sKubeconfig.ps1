param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [string]$OutputPath = "C:\K3s\runtime\kubeconfig.yml",
    [switch]$TestClusterConnection
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SourcePath)) {
    throw "Source kubeconfig not found: $SourcePath"
}

$resolvedSource = (Resolve-Path $SourcePath).Path
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$resolvedOutputDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $resolvedOutputPath)).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath("C:\K3s\runtime").TrimEnd('\')
if (-not ($resolvedOutputDir.Equals($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputDir.StartsWith($runtimeRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputPath must stay under C:\K3s\runtime: $resolvedOutputPath"
}
if (-not (Test-Path $resolvedOutputDir)) {
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
}

Copy-Item -LiteralPath $resolvedSource -Destination $resolvedOutputPath -Force
$resolvedOutput = (Resolve-Path $resolvedOutputPath).Path

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

$contexts = @(& kubectl --kubeconfig $resolvedOutput config get-contexts -o name)
if ($LASTEXITCODE -ne 0 -or $contexts.Count -eq 0) {
    throw "Imported kubeconfig has no contexts: $resolvedOutput"
}

$currentContext = & kubectl --kubeconfig $resolvedOutput config current-context
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentContext)) {
    throw "Imported kubeconfig has no current-context: $resolvedOutput"
}

Write-Host "Imported kubeconfig: $resolvedOutput"
Write-Host "Current context: $currentContext"
Write-Host "Available contexts:"
$contexts | ForEach-Object { Write-Host "  $_" }

if ($TestClusterConnection) {
    & kubectl --kubeconfig $resolvedOutput get namespace default | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Imported kubeconfig could not reach the cluster."
    }
    Write-Host "Cluster connection check passed."
}
