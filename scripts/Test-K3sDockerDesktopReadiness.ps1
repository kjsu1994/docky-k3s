param(
    [string]$Root = "C:\K3s",
    [string]$BackendImage,
    [string]$FrontendImage,
    [string]$Kubeconfig,
    [switch]$RequireKubernetesContext,
    [switch]$SkipImageRuntime,
    [switch]$RequireLocalImageRuntime
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

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1") `
    -Environment docker-desktop `
    -FailOnPlaceholderImages
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop manifest gate failed."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sExternalDependencies.ps1") `
    -Environment docker-desktop `
    -FailOnUnresolved
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop external dependency gate failed."
}

$rendered = & kubectl kustomize (Join-Path $Root "overlays\docker-desktop")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to render Docker Desktop overlay for image discovery."
}
$renderedText = $rendered -join [Environment]::NewLine
if ([string]::IsNullOrWhiteSpace($BackendImage)) {
    $backendMatch = [regex]::Match($renderedText, 'image:\s+(ghcr\.io/kjsu1994/docky-backend:[^\s]+)')
    if (-not $backendMatch.Success) { throw "Failed to discover backend image from Docker Desktop overlay." }
    $BackendImage = $backendMatch.Groups[1].Value
}
if ([string]::IsNullOrWhiteSpace($FrontendImage)) {
    $frontendMatch = [regex]::Match($renderedText, 'image:\s+(ghcr\.io/kjsu1994/docky-frontend-nginx:[^\s]+)')
    if (-not $frontendMatch.Success) { throw "Failed to discover frontend image from Docker Desktop overlay." }
    $FrontendImage = $frontendMatch.Groups[1].Value
}
Write-Host "Docker Desktop backend image: $BackendImage"
Write-Host "Docker Desktop frontend image: $FrontendImage"


& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sReleaseImages.ps1") `
    -Environment docker-desktop `
    -Root $Root `
    -RequireRegistryAvailability
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop registry image availability gate failed."
}

if ($RequireLocalImageRuntime -and -not $SkipImageRuntime) {
    foreach ($image in @($BackendImage, $FrontendImage)) {
        docker image inspect $image | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Required local Docker image not found: $image"
        }
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sImageRuntime.ps1") `
        -BackendImage $BackendImage `
        -FrontendImage $FrontendImage
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Desktop local image runtime gate failed."
    }
} elseif (-not $RequireLocalImageRuntime) {
    Write-Host "Skipping local Docker image runtime check; Docker Desktop overlay uses GHCR image pull secret."
}

if ($RequireKubernetesContext) {
    $hostArgs = @("-RequireKubernetesContext")
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $hostArgs += @("-Kubeconfig", $Kubeconfig)
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sHostPrereqs.ps1") @hostArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Desktop Kubernetes host prerequisite gate failed."
    }

    $clusterArgs = @("-Environment", "docker-desktop")
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $clusterArgs += @("-Kubeconfig", $Kubeconfig)
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sClusterPrereqs.ps1") @clusterArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Desktop Kubernetes cluster prerequisite gate failed."
    }
} else {
    $previousNativePreference = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        $previousNativePreference = $Global:PSNativeCommandUseErrorActionPreference
        $Global:PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $context = & kubectl config current-context 2>$null
        $contextExitCode = $LASTEXITCODE
    } catch {
        $context = ""
        $contextExitCode = 1
    } finally {
        if ($null -ne $previousNativePreference) {
            $Global:PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($contextExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($context)) {
        Write-Warning "kubectl has no current context. Docker Desktop manifests and local images are ready, but Kubernetes apply cannot be verified until a context exists."
    } else {
        Write-Host "kubectl current-context: $context"
    }
}

Write-Host "Docker Desktop K3s overlay readiness checks passed."
