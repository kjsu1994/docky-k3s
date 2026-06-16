param(
    [string]$Root = "C:\K3s",
    [ValidateSet("all", "production", "staging", "docker-desktop")]
    [string]$Environment = "all",
    [switch]$FailOnPlaceholderImages
)

$ErrorActionPreference = "Stop"

$allManifestRoots = [ordered]@{
    "ingress-nginx"   = Join-Path $Root "ingress-nginx"
    "production"      = Join-Path $Root "manifests"
    "staging"         = Join-Path $Root "overlays\staging"
    "docker-desktop"  = Join-Path $Root "overlays\docker-desktop"
    "cloudflared"     = Join-Path $Root "cloudflared"
}

$manifestRoots = switch ($Environment) {
    "production" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["production"])
        break
    }
    "staging" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["staging"])
        break
    }
    "docker-desktop" {
        @($allManifestRoots["ingress-nginx"], $allManifestRoots["docker-desktop"])
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
    if ($leaf -eq "manifests") {
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
        Assert-RenderedContains -Text $renderedText -Pattern "APP_CORS_ALLOWED_ORIGIN_PATTERNS:\s+http://localhost:8080,http://127\.0\.0\.1:8080" -Context "Docker Desktop CORS"
        Assert-RenderedContains -Text $renderedText -Pattern "GOOGLE_REDIRECT_URI:\s+http://localhost:8080/login/oauth2/code/google" -Context "Docker Desktop Google redirect"
        Assert-RenderedContains -Text $renderedText -Pattern "NAVER_REDIRECT_URI:\s+http://localhost:8080/login/oauth2/code/naver" -Context "Docker Desktop Naver redirect"
        Assert-RenderedContains -Text $renderedText -Pattern "S3_PRESIGNED_PUBLIC_ENDPOINT:\s+http://localhost:8080" -Context "Docker Desktop S3 public endpoint"
        Assert-RenderedContains -Text $renderedText -Pattern "OLLAMA_BASE_URL:\s+http://ollama:11435" -Context "Docker Desktop Ollama endpoint"
        Assert-RenderedNotContains -Text $renderedText -Pattern "docky\.co\.kr" -Context "Docker Desktop overlay isolation"
    }
}

Write-Host "K3s manifests rendered successfully for $Environment."
if ($placeholderFound) {
    Write-Warning "Rendered manifests still contain placeholder image values. Update image names before applying."
}
