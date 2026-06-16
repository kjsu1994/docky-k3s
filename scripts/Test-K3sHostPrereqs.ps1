param(
    [string]$Kubeconfig,
    [switch]$RequireKubernetesContext,
    [switch]$RequireK3sBinary,
    [switch]$SkipDocker
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not (Test-CommandAvailable "kubectl")) {
    $failures.Add("kubectl is not installed or not on PATH.")
} else {
    kubectl version --client=true | Out-Host

    try {
        $contexts = @(& kubectl config get-contexts -o name 2>$null)
    } catch {
        $contexts = @()
    }
    if ($LASTEXITCODE -ne 0) {
        $contexts = @()
    }

    try {
        $currentContext = & kubectl config current-context 2>$null
    } catch {
        $currentContext = $null
    }
    if ($LASTEXITCODE -ne 0) {
        $currentContext = $null
    }

    if ($contexts.Count -eq 0) {
        Write-Warning "No Kubernetes contexts are configured."
    } else {
        Write-Host "Kubernetes contexts:"
        $contexts | ForEach-Object { Write-Host "  $_" }
    }

    if ([string]::IsNullOrWhiteSpace($currentContext)) {
        Write-Warning "kubectl current-context is not set."
        if ($RequireKubernetesContext) {
            $failures.Add("A Kubernetes context is required but current-context is not set.")
        }
    } else {
        Write-Host "Current Kubernetes context: $currentContext"
    }
}

if ($SkipDocker) {
    Write-Host "Docker check skipped."
} else {
    if (-not (Test-CommandAvailable "docker")) {
        $failures.Add("docker is not installed or not on PATH.")
    } else {
        try {
            docker version --format "Docker client={{.Client.Version}} server={{.Server.Version}}"
        } catch {
            $failures.Add("Docker CLI is installed but the daemon is not reachable.")
        }
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("Docker CLI is installed but the daemon is not reachable.")
        }
    }
}

if (-not (Test-CommandAvailable "k3s")) {
    $message = "k3s binary is not installed or not on PATH."
    if ($RequireK3sBinary) {
        $failures.Add($message)
    } else {
        Write-Warning $message
    }
} else {
    k3s --version | Select-Object -First 1 | Out-Host
}

if (-not (Test-CommandAvailable "helm")) {
    Write-Warning "helm is not installed or not on PATH. This migration uses static ingress-nginx manifests, so helm is optional."
} else {
    helm version --short | Out-Host
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Host prerequisite checks passed."
