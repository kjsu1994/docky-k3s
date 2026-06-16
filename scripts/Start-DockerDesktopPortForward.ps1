param(
    [string]$Kubeconfig,
    [int]$LocalPort = 8080,
    [int]$IngressPort = 80,
    [string]$Namespace = "ingress-nginx"
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

Write-Host "Forwarding http://localhost:$LocalPort to ingress-nginx controller."
Write-Host "Keep this process running while testing Docker Desktop Kubernetes."
kubectl -n $Namespace port-forward svc/ingress-nginx-controller "${LocalPort}:${IngressPort}"
