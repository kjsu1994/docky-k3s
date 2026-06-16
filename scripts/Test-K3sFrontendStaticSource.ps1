param(
    [string]$DistPath = "C:\compose\minio-data\client\current",
    [switch]$FailOnLocalhostReferences
)

$ErrorActionPreference = "Stop"

function Resolve-StaticReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $cleanReference = ($Reference -split '[?#]', 2)[0]
    if ([string]::IsNullOrWhiteSpace($cleanReference)) {
        return $null
    }
    if ($cleanReference -match '(?i)^((https?:)?//|data:|mailto:|tel:|#)') {
        return $null
    }

    $relativePath = $cleanReference.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    return Join-Path $BasePath $relativePath
}

if (-not (Test-Path $DistPath)) {
    throw "Frontend static source directory not found: $DistPath"
}

$resolvedDistPath = (Resolve-Path $DistPath).Path
$indexPath = Join-Path $resolvedDistPath "index.html"
if (-not (Test-Path $indexPath)) {
    throw "Frontend static source is missing index.html: $resolvedDistPath"
}

$assetsPath = Join-Path $resolvedDistPath "assets"
if (-not (Test-Path $assetsPath)) {
    throw "Frontend static source is missing assets directory: $assetsPath"
}

$assetFiles = @(Get-ChildItem -Path $assetsPath -File -ErrorAction Stop)
$jsFiles = @($assetFiles | Where-Object { $_.Extension -ieq ".js" })
$cssFiles = @($assetFiles | Where-Object { $_.Extension -ieq ".css" })
if ($jsFiles.Count -eq 0) {
    throw "Frontend static source assets directory has no JavaScript files: $assetsPath"
}
if ($cssFiles.Count -eq 0) {
    throw "Frontend static source assets directory has no CSS files: $assetsPath"
}

$indexHtml = Get-Content -Raw -Encoding UTF8 $indexPath
$attributePattern = '(?i)\b(?:src|href)=["'']([^"'']+)["'']'
$references = @([regex]::Matches($indexHtml, $attributePattern) | ForEach-Object { $_.Groups[1].Value })
$missingReferences = @()
foreach ($reference in $references) {
    $candidatePath = Resolve-StaticReference -BasePath $resolvedDistPath -Reference $reference
    if ($null -eq $candidatePath) {
        continue
    }
    if (-not (Test-Path $candidatePath)) {
        $missingReferences += "$reference -> $candidatePath"
    }
}
if ($missingReferences.Count -gt 0) {
    throw "index.html references missing static files:`n$($missingReferences -join "`n")"
}

$scanExtensions = @(".html", ".js", ".css", ".json", ".txt")
$localReferencePatterns = @(
    "http://localhost",
    "https://localhost",
    "http://127.0.0.1",
    "https://127.0.0.1",
    "host.docker.internal"
)
$scanFiles = Get-ChildItem -Path $resolvedDistPath -Recurse -File |
    Where-Object { $scanExtensions -contains $_.Extension.ToLowerInvariant() }

$localReferenceHits = @()
foreach ($file in $scanFiles) {
    $content = Get-Content -Raw -Encoding UTF8 $file.FullName
    foreach ($pattern in $localReferencePatterns) {
        if ($content.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $localReferenceHits += "$($file.FullName): $pattern"
        }
    }
}

if ($localReferenceHits.Count -gt 0) {
    $message = "Frontend static source contains local-only reference strings. Review them before production cutover:`n$($localReferenceHits -join "`n")"
    if ($FailOnLocalhostReferences) {
        throw $message
    }
    Write-Warning $message
}

Write-Host "Frontend static source validation passed: $resolvedDistPath"
Write-Host "Checked index references: $($references.Count)"
Write-Host "Asset files: $($assetFiles.Count)"
