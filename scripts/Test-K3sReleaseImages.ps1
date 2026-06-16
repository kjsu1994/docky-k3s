param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "production",
    [string]$Root = "C:\K3s",
    [switch]$RequireRegistryAvailability
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

$appRoot = switch ($Environment) {
    "staging" { Join-Path $Root "overlays\staging" }
    "docker-desktop" { Join-Path $Root "overlays\docker-desktop" }
    default { Join-Path $Root "manifests" }
}

if (-not (Test-Path $appRoot)) {
    throw "Manifest root not found: $appRoot"
}

$rendered = & kubectl kustomize $appRoot
if ($LASTEXITCODE -ne 0 -or -not $rendered) {
    throw "kubectl kustomize failed or produced no output: $appRoot"
}

$renderedText = $rendered -join [Environment]::NewLine
$imageMatches = [regex]::Matches(
    $renderedText,
    'image:\s+(?<image>ghcr\.io/kjsu1994/(?<name>docky-backend|docky-frontend-nginx):(?<tag>[A-Za-z0-9_.-]+))'
)

$imagesByName = @{}
foreach ($match in $imageMatches) {
    $name = $match.Groups["name"].Value
    $image = $match.Groups["image"].Value
    if (-not $imagesByName.ContainsKey($name)) {
        $imagesByName[$name] = New-Object System.Collections.Generic.HashSet[string]
    }
    [void]$imagesByName[$name].Add($image)
}

$requiredNames = @("docky-backend", "docky-frontend-nginx")
$findings = New-Object System.Collections.Generic.List[string]
foreach ($name in $requiredNames) {
    if (-not $imagesByName.ContainsKey($name) -or $imagesByName[$name].Count -eq 0) {
        $findings.Add("Missing required Docky image in rendered $Environment manifests: $name")
    }
}

$releaseBlockedTagPattern = '^(replace-me|latest|stable)$|^(local|dev|test|tmp|scratch)[_.-]|(compose-current|validator|verify|wip)'
foreach ($name in $imagesByName.Keys) {
    foreach ($image in $imagesByName[$name]) {
        $tag = ($image -split ':')[-1]
        if ($Environment -eq "docker-desktop") {
            if ($tag -eq "replace-me") {
                $findings.Add("Docker Desktop image still uses placeholder tag: $image")
            }
            continue
        }

        if ($tag -match $releaseBlockedTagPattern) {
            $findings.Add("$Environment image tag does not look like a release tag: $image")
        }
    }
}

if ($findings.Count -gt 0) {
    throw "Docky release image checks failed:`n$($findings -join [Environment]::NewLine)"
}

$uniqueImages = New-Object System.Collections.Generic.HashSet[string]
foreach ($name in $imagesByName.Keys) {
    foreach ($image in $imagesByName[$name]) {
        [void]$uniqueImages.Add($image)
    }
}

if ($RequireRegistryAvailability) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        throw "docker not found on PATH. Cannot verify registry image availability."
    }

    foreach ($image in $uniqueImages) {
        docker manifest inspect $image | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Registry image is not inspectable from this machine. Check push/auth/tag: $image"
        }
    }
}

Write-Host "Docky release image checks passed for $Environment."
foreach ($image in ($uniqueImages | Sort-Object)) {
    Write-Host "Image: $image"
}
