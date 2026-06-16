param(
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [switch]$IncludeExternalServices,
    [switch]$SkipOllama,
    [switch]$SkipIot
)

$ErrorActionPreference = "Stop"

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

$pod = (& kubectl get pods -n $Namespace -l "app.kubernetes.io/name=backend" -o "jsonpath={.items[0].metadata.name}" 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pod)) {
    throw "No backend pod found in namespace $Namespace."
}

function Invoke-BackendShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    Write-Host "Checking in-cluster connectivity: $Description"
    & kubectl exec -n $Namespace $pod -c backend -- sh -lc $Command | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "In-cluster connectivity check failed: $Description"
    }
}

$dnsNames = @("oracle", "redis", "minio", "backend", "nginx")
if (-not $SkipOllama) {
    $dnsNames += "ollama"
}

foreach ($name in $dnsNames) {
    Invoke-BackendShell -Description "DNS $name" -Command "getent hosts $name >/dev/null"
}

Invoke-BackendShell -Description "backend readiness over Service DNS" -Command "wget -q -T 10 -O - http://backend:8080/actuator/health/readiness >/tmp/k3s-backend-health.txt"
Invoke-BackendShell -Description "MinIO ready endpoint over Service DNS" -Command "wget -q -T 10 -O - http://minio:9000/minio/health/ready >/tmp/k3s-minio-health.txt"
Invoke-BackendShell -Description "nginx index over Service DNS" -Command "wget -q -T 10 -O - http://nginx/index.html >/tmp/k3s-nginx-index.html"

if (-not $SkipOllama) {
    Invoke-BackendShell -Description "Ollama API over Service DNS" -Command "wget -q -T 10 -O - http://ollama:11435/api/tags >/tmp/k3s-ollama-tags.json"
}
Write-Host "K3s in-cluster connectivity checks passed."
