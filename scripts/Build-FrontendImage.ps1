param(
    [Parameter(Mandatory = $true)]
    [string]$DistPath,
    [Parameter(Mandatory = $true)]
    [string]$ImageName,
    [string]$Root = "C:\K3s"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DistPath)) {
    throw "Dist directory not found: $DistPath"
}
if (-not (Test-Path (Join-Path $DistPath "index.html"))) {
    throw "Dist directory is missing index.html: $DistPath"
}
$resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
if (-not $resolvedRoot.Equals("C:\K3s", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Root must remain C:\K3s for generated Docker build context: $resolvedRoot"
}
$Root = $resolvedRoot

$context = Join-Path $Root "build\frontend\context"
$dockerfile = Join-Path $Root "build\frontend\Dockerfile"
if (-not (Test-Path $dockerfile)) {
    throw "Dockerfile not found: $dockerfile"
}

$resolvedDistPath = (Resolve-Path $DistPath).Path
$contextParent = Join-Path $Root "build\frontend"
if ($resolvedDistPath.StartsWith((Join-Path $contextParent "context"), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "DistPath must not be inside the generated build context because the context is cleaned before each build: $resolvedDistPath"
}

$staticSourceValidator = Join-Path $Root "scripts\Test-K3sFrontendStaticSource.ps1"
if (-not (Test-Path $staticSourceValidator)) {
    throw "Frontend static source validator not found: $staticSourceValidator"
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $staticSourceValidator -DistPath $resolvedDistPath
if ($LASTEXITCODE -ne 0) {
    throw "Frontend static source validation failed."
}

if (Test-Path $context) {
    $resolved = (Resolve-Path $context).Path
    if (-not $resolved.StartsWith($contextParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected context path: $resolved"
    }
    Remove-Item -LiteralPath $context -Recurse -Force
}

New-Item -ItemType Directory -Path $context -Force | Out-Null
Copy-Item -LiteralPath $resolvedDistPath -Destination (Join-Path $context "dist") -Recurse -Force

docker build -t $ImageName -f $dockerfile $context
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed."
}

Write-Host "Built frontend image: $ImageName"
