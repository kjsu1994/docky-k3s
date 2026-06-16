param(
    [string]$BackendImage,
    [string]$FrontendImage,
    [switch]$SkipBackendImage,
    [switch]$SkipFrontendImage
)

$ErrorActionPreference = "Stop"

if ($SkipBackendImage -and $SkipFrontendImage) {
    throw "At least one image must be tested."
}

if (-not $SkipBackendImage) {
    if ([string]::IsNullOrWhiteSpace($BackendImage)) {
        throw "Backend image is required unless -SkipBackendImage is passed."
    }

    docker run --rm --entrypoint java $BackendImage -version
    if ($LASTEXITCODE -ne 0) {
        throw "Backend image Java runtime check failed."
    }

    docker run --rm --entrypoint ffmpeg $BackendImage -version
    if ($LASTEXITCODE -ne 0) {
        throw "Backend image ffmpeg runtime check failed."
    }

    docker run --rm --entrypoint sh $BackendImage -c "command -v sh >/dev/null && command -v tar >/dev/null && command -v find >/dev/null && command -v getent >/dev/null && command -v wget >/dev/null && mkdir -p /tmp/k3s-runtime-check"
    if ($LASTEXITCODE -ne 0) {
        throw "Backend image helper-tool check failed. The image must include sh, tar, find, getent, wget, and mkdir for restore/helper validation pods."
    }

    Write-Host "Backend image runtime checks passed: $BackendImage"
}

if (-not $SkipFrontendImage) {
    if ([string]::IsNullOrWhiteSpace($FrontendImage)) {
        throw "Frontend image is required unless -SkipFrontendImage is passed."
    }

    docker run --rm --entrypoint sh $FrontendImage -c "test -f /usr/share/nginx/client/current/index.html"
    if ($LASTEXITCODE -ne 0) {
        throw "Frontend image is missing /usr/share/nginx/client/current/index.html."
    }

    Write-Host "Frontend image runtime checks passed: $FrontendImage"
}
