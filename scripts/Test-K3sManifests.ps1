param(
    [string]$Root = "C:\K3s",
    [ValidateSet("all", "production", "production-gpu", "production-gpu-runtimeclass", "staging", "staging-gpu", "staging-gpu-runtimeclass", "docker-desktop", "docker-gpu", "docker-gpu-runtimeclass")]
    [string]$Environment = "all",
    [switch]$FailOnPlaceholderImages
)

$ErrorActionPreference = "Stop"

$allManifestRoots = [ordered]@{
    "ingress-nginx"   = Join-Path $Root "ingress-nginx"
    "nvidia-device-plugin" = Join-Path $Root "nvidia-device-plugin"
    "nvidia-device-plugin-runtimeclass" = Join-Path $Root "nvidia-device-plugin-runtimeclass"
    "production"      = Join-Path $Root "manifests"
    "production-gpu"  = Join-Path $Root "overlays\production-ollama-gpu"
    "production-gpu-runtimeclass" = Join-Path $Root "overlays\production-ollama-gpu-runtimeclass"
    "staging"         = Join-Path $Root "overlays\staging"
    "staging-gpu"     = Join-Path $Root "overlays\staging-ollama-gpu"
    "staging-gpu-runtimeclass" = Join-Path $Root "overlays\staging-ollama-gpu-runtimeclass"
    "docker-desktop"  = Join-Path $Root "overlays\docker-desktop"
    "docker-gpu"      = Join-Path $Root "overlays\docker-desktop-ollama-gpu"
    "docker-gpu-runtimeclass" = Join-Path $Root "overlays\docker-desktop-ollama-gpu-runtimeclass"
    "cloudflared"     = Join-Path $Root "cloudflared"
}

$manifestRoots = switch ($Environment) {
    "production" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["production"])
        break
    }
    "production-gpu" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["production-gpu"])
        break
    }
    "production-gpu-runtimeclass" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["production-gpu-runtimeclass"])
        break
    }
    "staging" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["staging"])
        break
    }
    "staging-gpu" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["staging-gpu"])
        break
    }
    "staging-gpu-runtimeclass" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["staging-gpu-runtimeclass"])
        break
    }
    "docker-desktop" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["docker-desktop"])
        break
    }
    "docker-gpu" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["docker-gpu"])
        break
    }
    "docker-gpu-runtimeclass" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["nvidia-device-plugin"], $allManifestRoots["nvidia-device-plugin-runtimeclass"], $allManifestRoots["docker-gpu-runtimeclass"])
        break
    }
    default {
        @($allManifestRoots.Values)
        break
    }
}

foreach ($manifestRoot in $manifestRoots) {
    if (-not (Test-Path $manifestRoot)) {
        throw "Manifest root not found: $manifestRoot"
    }
}

$forbiddenPatterns = @(
    "C:\\compose",
    "spring-backend-blue",
    "spring-backend-green"
)

$manifestFiles = $manifestRoots | ForEach-Object {
    Get-ChildItem -Path $_ -Recurse -File -Include *.yml
}
foreach ($pattern in $forbiddenPatterns) {
    $hits = $manifestFiles | Select-String -Pattern $pattern
    if ($hits) {
        $lines = $hits | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
        throw "Forbidden Compose-specific reference found:`n$($lines -join [Environment]::NewLine)"
    }
}

function Assert-RenderedContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )
    if ($Text -notmatch $Pattern) {
        throw "Rendered manifest missing expected pattern for ${Context}: $Pattern"
    }
}

function Assert-RenderedNotContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )
    if ($Text -match $Pattern) {
        throw "Rendered manifest contains forbidden pattern for ${Context}: $Pattern"
    }
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

$placeholderFound = $false
foreach ($manifestRoot in $manifestRoots) {
    $rendered = & kubectl kustomize $manifestRoot
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl kustomize failed: $manifestRoot"
    }
    if (-not $rendered) {
        throw "kubectl kustomize produced no output: $manifestRoot"
    }
    $renderedText = $rendered -join [Environment]::NewLine

    if (($manifestRoot -notmatch "ingress-nginx") -and ($renderedText -match "replace-me|registry\.example\.com")) {
        if ($FailOnPlaceholderImages) {
            throw "Rendered manifests still contain placeholder image values: $manifestRoot"
        }
        $placeholderFound = $true
    }

    $leaf = Split-Path -Leaf $manifestRoot
    if ($leaf -eq "nvidia-device-plugin") {
        Assert-RenderedContains -Text $renderedText -Pattern "kind:\s+DaemonSet[\s\S]*name:\s+nvidia-device-plugin-daemonset" -Context "NVIDIA device plugin DaemonSet"
        Assert-RenderedContains -Text $renderedText -Pattern "namespace:\s+kube-system" -Context "NVIDIA device plugin namespace"
        Assert-RenderedContains -Text $renderedText -Pattern "image:\s+nvcr\.io/nvidia/k8s-device-plugin@sha256:[a-fA-F0-9]{64}" -Context "NVIDIA device plugin pinned image"
        Assert-RenderedContains -Text $renderedText -Pattern "kind:\s+RuntimeClass" -Context "NVIDIA RuntimeClass kind"
        Assert-RenderedContains -Text $renderedText -Pattern "handler:\s+nvidia" -Context "NVIDIA RuntimeClass handler"
        Assert-RenderedContains -Text $renderedText -Pattern "name:\s+FAIL_ON_INIT_ERROR[\s\S]*value:\s+""false""" -Context "NVIDIA device plugin no-GPU fallback"
    } elseif ($leaf -eq "nvidia-device-plugin-runtimeclass") {
        Assert-RenderedContains -Text $renderedText -Pattern "kind:\s+DaemonSet[\s\S]*name:\s+nvidia-device-plugin-daemonset" -Context "NVIDIA RuntimeClass retry DaemonSet"
        Assert-RenderedContains -Text $renderedText -Pattern "runtimeClassName:\s+nvidia" -Context "NVIDIA RuntimeClass retry"
        Assert-RenderedContains -Text $renderedText -Pattern "kind:\s+RuntimeClass" -Context "NVIDIA RuntimeClass retry kind"
        Assert-RenderedContains -Text $renderedText -Pattern "handler:\s+nvidia" -Context "NVIDIA RuntimeClass retry handler"
    } elseif ($leaf -eq "manifests") {
        foreach ($pattern in @(
            "kind:\s+PersistentVolumeClaim[\s\S]*name:\s+oracle-data",
            "kind:\s+PersistentVolumeClaim[\s\S]*name:\s+minio-data",
            "kind:\s+PersistentVolumeClaim[\s\S]*name:\s+redis-data",
            "kind:\s+PersistentVolumeClaim[\s\S]*name:\s+ollama-data",
            "kind:\s+StatefulSet[\s\S]*name:\s+oracle",
            "kind:\s+StatefulSet[\s\S]*name:\s+minio",
            "kind:\s+Deployment[\s\S]*name:\s+redis",
            "kind:\s+StatefulSet[\s\S]*name:\s+ollama",
            "kind:\s+Deployment[\s\S]*name:\s+backend",
            "kind:\s+Deployment[\s\S]*name:\s+nginx",
            "kind:\s+Service[\s\S]*name:\s+ollama",
            "imagePullSecrets:[\s\S]*name:\s+ghcr-pull-secret",
            "readinessProbe:",
            "livenessProbe:"
        )) {
            Assert-RenderedContains -Text $renderedText -Pattern $pattern -Context "production workload baseline"
        }
        Assert-RenderedContains -Text $renderedText -Pattern "host:\s+docky\.co\.kr" -Context "production host"
        Assert-RenderedContains -Text $renderedText -Pattern "host:\s+www\.docky\.co\.kr" -Context "production www host"
        Assert-RenderedContains -Text $renderedText -Pattern "S3_PRESIGNED_PUBLIC_ENDPOINT:\s+https://docky\.co\.kr" -Context "production S3 public endpoint"
        Assert-RenderedContains -Text $renderedText -Pattern "OLLAMA_ENABLED:\s+""true""" -Context "production Ollama parity"
        Assert-RenderedContains -Text $renderedText -Pattern "KIS_ENABLED:\s+""true""" -Context "production KIS parity"
        Assert-RenderedContains -Text $renderedText -Pattern "OLLAMA_BASE_URL:\s+http://ollama:11435" -Context "production Ollama endpoint"
        Assert-RenderedNotContains -Text $renderedText -Pattern "staging\.docky\.co\.kr" -Context "production overlay isolation"
        Assert-RenderedNotContains -Text $renderedText -Pattern "host:\s+localhost" -Context "production overlay isolation"
        Assert-RenderedNotContains -Text $renderedText -Pattern "host\.docker\.internal" -Context "production external dependency isolation"
    } elseif ($leaf -eq "staging") {
        Assert-RenderedContains -Text $renderedText -Pattern "imagePullSecrets:[\s\S]*name:\s+ghcr-pull-secret" -Context "staging image pull secret"
        Assert-RenderedContains -Text $renderedText -Pattern "host:\s+staging\.docky\.co\.kr" -Context "staging host"
        Assert-RenderedContains -Text $renderedText -Pattern "APP_CORS_ALLOWED_ORIGIN_PATTERNS:\s+https://staging\.docky\.co\.kr" -Context "staging CORS"
        Assert-RenderedContains -Text $renderedText -Pattern "GOOGLE_REDIRECT_URI:\s+https://staging\.docky\.co\.kr/login/oauth2/code/google" -Context "staging Google redirect"
        Assert-RenderedContains -Text $renderedText -Pattern "NAVER_REDIRECT_URI:\s+https://staging\.docky\.co\.kr/login/oauth2/code/naver" -Context "staging Naver redirect"
        Assert-RenderedContains -Text $renderedText -Pattern "S3_PRESIGNED_PUBLIC_ENDPOINT:\s+https://staging\.docky\.co\.kr" -Context "staging S3 public endpoint"
        Assert-RenderedContains -Text $renderedText -Pattern "OLLAMA_BASE_URL:\s+http://ollama:11435" -Context "staging Ollama endpoint"
        Assert-RenderedNotContains -Text $renderedText -Pattern "host:\s+docky\.co\.kr" -Context "staging overlay isolation"
        Assert-RenderedNotContains -Text $renderedText -Pattern "www\.docky\.co\.kr" -Context "staging overlay isolation"
        Assert-RenderedNotContains -Text $renderedText -Pattern "S3_PRESIGNED_PUBLIC_ENDPOINT:\s+https://docky\.co\.kr" -Context "staging S3 isolation"
        Assert-RenderedNotContains -Text $renderedText -Pattern "host\.docker\.internal" -Context "staging external dependency isolation"
    } elseif ($leaf -eq "docker-desktop") {
        Assert-RenderedContains -Text $renderedText -Pattern "imagePullSecrets:[\s\S]*name:\s+ghcr-pull-secret" -Context "Docker Desktop GHCR image pull secret"
        Assert-RenderedContains -Text $renderedText -Pattern "host:\s+localhost" -Context "Docker Desktop host"
        Assert-RenderedContains -Text $renderedText -Pattern "APP_CORS_ALLOWED_ORIGIN_PATTERNS:\s+https://docky\.co\.kr,https://www\.docky\.co\.kr" -Context "Docker Desktop CORS"
        Assert-RenderedContains -Text $renderedText -Pattern "GOOGLE_REDIRECT_URI:\s+https://docky\.co\.kr/login/oauth2/code/google" -Context "Docker Desktop Google redirect"
        Assert-RenderedContains -Text $renderedText -Pattern "NAVER_REDIRECT_URI:\s+https://docky\.co\.kr/login/oauth2/code/naver" -Context "Docker Desktop Naver redirect"
        Assert-RenderedContains -Text $renderedText -Pattern "S3_PRESIGNED_PUBLIC_ENDPOINT:\s+https://docky\.co\.kr" -Context "Docker Desktop S3 public endpoint"
        Assert-RenderedContains -Text $renderedText -Pattern "OLLAMA_BASE_URL:\s+http://ollama:11435" -Context "Docker Desktop Ollama endpoint"
        Assert-RenderedNotContains -Text $renderedText -Pattern "staging\.docky\.co\.kr" -Context "Docker Desktop overlay isolation"
    } elseif ($leaf -match "ollama-gpu$") {
        Assert-RenderedContains -Text $renderedText -Pattern "kind:\s+StatefulSet[\s\S]*name:\s+ollama" -Context "$leaf Ollama StatefulSet"
        Assert-RenderedContains -Text $renderedText -Pattern "name:\s+OLLAMA_FLASH_ATTENTION[\s\S]*value:\s+""1""" -Context "$leaf Ollama flash attention"
        Assert-RenderedContains -Text $renderedText -Pattern "name:\s+NVIDIA_VISIBLE_DEVICES[\s\S]*value:\s+all" -Context "$leaf NVIDIA visible devices"
        Assert-RenderedContains -Text $renderedText -Pattern "nvidia\.com/gpu:\s+""?1""?" -Context "$leaf NVIDIA GPU limit"
        Assert-RenderedNotContains -Text $renderedText -Pattern "runtimeClassName:\s+nvidia" -Context "$leaf default runtime selection"
    } elseif ($leaf -match "ollama-gpu-runtimeclass$") {
        Assert-RenderedContains -Text $renderedText -Pattern "kind:\s+StatefulSet[\s\S]*name:\s+ollama" -Context "$leaf Ollama StatefulSet"
        Assert-RenderedContains -Text $renderedText -Pattern "runtimeClassName:\s+nvidia" -Context "$leaf NVIDIA RuntimeClass"
        Assert-RenderedContains -Text $renderedText -Pattern "nvidia\.com/gpu:\s+""?1""?" -Context "$leaf NVIDIA GPU limit"
    }
}

Write-Host "K3s manifests rendered successfully for $Environment."
if ($placeholderFound) {
    Write-Warning "Rendered manifests still contain placeholder image values. Update image names before applying."
}
