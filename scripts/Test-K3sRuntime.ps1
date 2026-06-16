param(
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [int]$TimeoutSeconds = 600,
    [switch]$IncludeCloudflared
)

$ErrorActionPreference = "Stop"

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

& kubectl get namespace $Namespace | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Namespace not found: $Namespace"
}

Write-Host "Waiting for rollout: deployment/ingress-nginx-controller"
& kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout="${TimeoutSeconds}s" | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Rollout failed or timed out: deployment/ingress-nginx-controller"
}

$rollouts = @(
    "deployment/redis",
    "statefulset/oracle",
    "statefulset/minio",
    "statefulset/ollama",
    "deployment/backend",
    "deployment/nginx"
)

if ($IncludeCloudflared) {
    $rollouts += "deployment/cloudflared"
}

foreach ($target in $rollouts) {
    Write-Host "Waiting for rollout: $target"
    & kubectl rollout status $target -n $Namespace --timeout="${TimeoutSeconds}s" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Rollout failed or timed out: $target"
    }
}

Write-Host "Current pods:"
& kubectl get pods -n $Namespace -o wide | Out-Host

Write-Host "Current PVCs:"
& kubectl get pvc -n $Namespace -o wide | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read PVC status."
}

$requiredPvcs = @("oracle-data", "minio-data", "redis-data", "ollama-data")
foreach ($pvc in $requiredPvcs) {
    $phase = (& kubectl get pvc $pvc -n $Namespace -o "jsonpath={.status.phase}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($phase)) {
        throw "Required PVC not found or unreadable: $pvc"
    }
    if ($phase.Trim() -ne "Bound") {
        throw "PVC is not Bound: $pvc status=$phase"
    }
}

Write-Host "Current services:"
& kubectl get svc -n $Namespace -o wide | Out-Host

Write-Host "Current ingress:"
& kubectl get ingress -n $Namespace -o wide | Out-Host

Write-Host "K3s runtime rollout checks passed."
