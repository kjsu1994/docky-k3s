param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath,
    [Parameter(Mandatory = $true)]
    [string]$ImageName,
    [string]$Root = "C:\K3s"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $JarPath)) {
    throw "Jar not found: $JarPath"
}
$resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
if (-not $resolvedRoot.Equals("C:\K3s", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Root must remain C:\K3s for generated Docker build context: $resolvedRoot"
}
$Root = $resolvedRoot

$context = Join-Path $Root "build\backend\context"
$dockerfile = Join-Path $Root "build\backend\Dockerfile"
if (-not (Test-Path $dockerfile)) {
    throw "Dockerfile not found: $dockerfile"
}

$resolvedJarPath = (Resolve-Path $JarPath).Path
$contextParent = Join-Path $Root "build\backend"
if ($resolvedJarPath.StartsWith((Join-Path $contextParent "context"), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "JarPath must not be inside the generated build context because the context is cleaned before each build: $resolvedJarPath"
}

if (Test-Path $context) {
    $resolved = (Resolve-Path $context).Path
    if (-not $resolved.StartsWith($contextParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected context path: $resolved"
    }
    Remove-Item -LiteralPath $context -Recurse -Force
}

New-Item -ItemType Directory -Path $context -Force | Out-Null
Copy-Item -LiteralPath $resolvedJarPath -Destination (Join-Path $context "app.jar") -Force

docker build -t $ImageName -f $dockerfile $context
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed."
}

Write-Host "Built backend image: $ImageName"
