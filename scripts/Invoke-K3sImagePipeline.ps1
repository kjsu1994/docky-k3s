param(
    [string]$BackendRoot = "C:\Users\honeybadger\Desktop\ctfmon_project\CommunityServer\server",
    [string]$FrontendRoot = "C:\Users\honeybadger\Desktop\ctfmon_project\client\api-client-ui",
    [string]$FrontendDistPath,
    [switch]$UseComposeFrontendCurrent,
    [string]$Tag = (Get-Date -Format "yyyyMMdd-HHmmss"),
    [switch]$SkipBackendBuild,
    [switch]$SkipFrontendBuild,
    [switch]$SkipBackendImage,
    [switch]$SkipFrontendImage,
    [switch]$Push,
    [switch]$UpdateManifests
)

$ErrorActionPreference = "Stop"
$root = "C:\K3s"
$backendImage = "ghcr.io/kjsu1994/docky-backend:$Tag"
$frontendImage = "ghcr.io/kjsu1994/docky-frontend-nginx:$Tag"

if ($Tag -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
    throw "Invalid image tag: $Tag"
}

if ($SkipBackendImage -and $SkipFrontendImage) {
    throw "At least one image must be built. Do not pass both -SkipBackendImage and -SkipFrontendImage."
}

if (-not $SkipBackendImage -and -not (Test-Path $BackendRoot)) {
    throw "Backend root not found: $BackendRoot"
}
if (-not $SkipFrontendImage -and -not $UseComposeFrontendCurrent -and [string]::IsNullOrWhiteSpace($FrontendDistPath) -and -not (Test-Path $FrontendRoot)) {
    throw "Frontend root not found: $FrontendRoot"
}
if ($UseComposeFrontendCurrent -and -not [string]::IsNullOrWhiteSpace($FrontendDistPath)) {
    throw "Use either -UseComposeFrontendCurrent or -FrontendDistPath, not both."
}
if ($UseComposeFrontendCurrent) {
    $FrontendDistPath = "C:\compose\minio-data\client\current"
}
if (-not [string]::IsNullOrWhiteSpace($FrontendDistPath)) {
    if (-not (Test-Path $FrontendDistPath)) {
        throw "Frontend dist path not found: $FrontendDistPath"
    }
    $resolvedFrontendDistPath = (Resolve-Path $FrontendDistPath).Path
    if ($UseComposeFrontendCurrent -and -not $resolvedFrontendDistPath.Equals("C:\compose\minio-data\client\current", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Compose frontend current path must remain C:\compose\minio-data\client\current: $resolvedFrontendDistPath"
    }
    if (-not (Test-Path (Join-Path $resolvedFrontendDistPath "index.html"))) {
        throw "Frontend dist path is missing index.html: $resolvedFrontendDistPath"
    }
}

if (-not $SkipBackendImage -and -not $SkipBackendBuild) {
    Push-Location $BackendRoot
    try {
        .\gradlew.bat bootJar
        if ($LASTEXITCODE -ne 0) { throw "Backend bootJar failed." }
    } finally {
        Pop-Location
    }
}

if (-not $SkipBackendImage) {
    $jarPath = Join-Path $BackendRoot "build\libs\app.jar"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Build-BackendImage.ps1") `
        -JarPath $jarPath `
        -ImageName $backendImage
    if ($LASTEXITCODE -ne 0) { throw "Backend image build failed." }
}

if (-not $SkipFrontendImage -and [string]::IsNullOrWhiteSpace($FrontendDistPath) -and -not $SkipFrontendBuild) {
    Push-Location $FrontendRoot
    try {
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "Frontend build failed." }
    } finally {
        Pop-Location
    }
}

if (-not $SkipFrontendImage) {
    $distPath = if ([string]::IsNullOrWhiteSpace($FrontendDistPath)) {
        Join-Path $FrontendRoot "dist"
    } else {
        $resolvedFrontendDistPath
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Build-FrontendImage.ps1") `
        -DistPath $distPath `
        -ImageName $frontendImage
    if ($LASTEXITCODE -ne 0) { throw "Frontend image build failed." }
}

if ($Push) {
    if (-not $SkipBackendImage) {
        docker push $backendImage
        if ($LASTEXITCODE -ne 0) { throw "Backend image push failed." }
    }
    if (-not $SkipFrontendImage) {
        docker push $frontendImage
        if ($LASTEXITCODE -ne 0) { throw "Frontend image push failed." }
    }
}

if ($UpdateManifests) {
    $tagArgs = @()
    if (-not $SkipBackendImage) {
        $tagArgs += @("-BackendTag", $Tag)
    }
    if (-not $SkipFrontendImage) {
        $tagArgs += @("-FrontendTag", $Tag)
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Set-K3sImageTags.ps1") @tagArgs
    if ($LASTEXITCODE -ne 0) { throw "Failed to update manifest image tags." }
}

if (-not $SkipBackendImage) {
    Write-Host "Backend image : $backendImage"
}
if (-not $SkipFrontendImage) {
    Write-Host "Frontend image: $frontendImage"
}
if (-not $Push) {
    Write-Warning "Images were built locally only. Use -Push after docker login to publish to GHCR."
}
if (-not $UpdateManifests) {
    Write-Warning "Manifest image tags were not updated. Use -UpdateManifests to write $Tag into kustomization.yml."
}
