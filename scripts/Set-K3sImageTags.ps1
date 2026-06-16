param(
    [string]$BackendTag,
    [string]$FrontendTag,
    [string]$KustomizationPath = "C:\K3s\manifests\kustomization.yml"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $KustomizationPath)) {
    throw "Kustomization not found: $KustomizationPath"
}
$resolvedKustomizationPath = (Resolve-Path $KustomizationPath).Path
$k3sRoot = [System.IO.Path]::GetFullPath("C:\K3s").TrimEnd('\')
if (-not ($resolvedKustomizationPath.Equals($k3sRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedKustomizationPath.StartsWith($k3sRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "KustomizationPath must stay under C:\K3s: $resolvedKustomizationPath"
}

if ([string]::IsNullOrWhiteSpace($BackendTag) -and [string]::IsNullOrWhiteSpace($FrontendTag)) {
    throw "Provide at least one image tag: -BackendTag and/or -FrontendTag."
}

foreach ($tag in @($BackendTag, $FrontendTag)) {
    if ([string]::IsNullOrWhiteSpace($tag)) {
        continue
    }
    if ($tag -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        throw "Invalid image tag: $tag"
    }
}

$lines = [System.Collections.Generic.List[string]](Get-Content -Path $resolvedKustomizationPath)
$currentImage = $null
$backendUpdated = $false
$frontendUpdated = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*-\s+name:\s+(docky/backend|ghcr\.io/kjsu1994/docky-backend)\s*$') {
        $currentImage = "backend"
        continue
    }
    if ($line -match '^\s*-\s+name:\s+(docky/frontend-nginx|ghcr\.io/kjsu1994/docky-frontend-nginx)\s*$') {
        $currentImage = "frontend"
        continue
    }
    if ($line -match '^\s*-\s+name:\s+') {
        $currentImage = $null
        continue
    }
    if ($currentImage -eq "backend" -and -not [string]::IsNullOrWhiteSpace($BackendTag) -and $line -match '^\s+newTag:\s+') {
        $lines[$i] = "    newTag: $BackendTag"
        $backendUpdated = $true
        $currentImage = $null
        continue
    }
    if ($currentImage -eq "frontend" -and -not [string]::IsNullOrWhiteSpace($FrontendTag) -and $line -match '^\s+newTag:\s+') {
        $lines[$i] = "    newTag: $FrontendTag"
        $frontendUpdated = $true
        $currentImage = $null
        continue
    }
}

if (-not [string]::IsNullOrWhiteSpace($BackendTag) -and -not $backendUpdated) {
    throw "Failed to update backend image tag."
}
if (-not [string]::IsNullOrWhiteSpace($FrontendTag) -and -not $frontendUpdated) {
    throw "Failed to update frontend image tag."
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedKustomizationPath, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, $utf8NoBom)
Write-Host "Updated image tags in $resolvedKustomizationPath"
if (-not [string]::IsNullOrWhiteSpace($BackendTag)) {
    Write-Host "Backend : ghcr.io/kjsu1994/docky-backend:$BackendTag"
}
if (-not [string]::IsNullOrWhiteSpace($FrontendTag)) {
    Write-Host "Frontend: ghcr.io/kjsu1994/docky-frontend-nginx:$FrontendTag"
}
