param(
    [string]$Root = "C:\K3s",
    [switch]$IncludeCloudflared,
    [switch]$IncludeJobs,
    [switch]$IncludeBuildFiles,
    [switch]$IncludeScripts,
    [switch]$FailOnMutableTags
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

function Test-ImageReferenceMutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $ref = $Reference.Trim().Trim('"').Trim("'")
    if ($ref -match '@sha256:[a-fA-F0-9]{64}') {
        return $false
    }

    $lastSlash = $ref.LastIndexOf('/')
    $lastColon = $ref.LastIndexOf(':')
    if ($lastColon -lt 0 -or $lastColon -lt $lastSlash) {
        return $true
    }

    $tag = $ref.Substring($lastColon + 1)
    return $tag -in @("latest", "stable")
}

function Test-ImageReferenceAllowsTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $ref = $Reference.Trim().Trim('"').Trim("'")
    return (
        $ref -like "docky/backend:*" -or
        $ref -like "docky/frontend-nginx:*" -or
        $ref -like "ghcr.io/kjsu1994/docky-backend:*" -or
        $ref -like "ghcr.io/kjsu1994/docky-frontend-nginx:*"
    )
}

function Test-ImageReferenceMissingDigest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $ref = $Reference.Trim().Trim('"').Trim("'")
    if ($ref -match '@sha256:[a-fA-F0-9]{64}') {
        return $false
    }
    return -not (Test-ImageReferenceAllowsTag -Reference $ref)
}

$scanRoots = New-Object System.Collections.Generic.List[string]
$scanRoots.Add((Join-Path $Root "manifests")) | Out-Null
if ($IncludeJobs) {
    $scanRoots.Add((Join-Path $Root "jobs")) | Out-Null
}
if ($IncludeCloudflared) {
    $scanRoots.Add((Join-Path $Root "cloudflared")) | Out-Null
}
if ($IncludeBuildFiles) {
    $scanRoots.Add((Join-Path $Root "build")) | Out-Null
}
if ($IncludeScripts) {
    $scanRoots.Add((Join-Path $Root "scripts")) | Out-Null
}

$findings = New-Object System.Collections.Generic.List[object]
foreach ($scanRoot in $scanRoots) {
    if (-not (Test-Path $scanRoot)) {
        continue
    }

    $files = Get-ChildItem -Path $scanRoot -Recurse -File -Include *.yml,Dockerfile,*.ps1
    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in Get-Content -Path $file.FullName) {
            $lineNumber++
            $imageRef = $null
            if ($line -match '^\s*image:\s+["'']?([^"''\s]+)') {
                $imageRef = $matches[1]
            } elseif ($line -match '^\s*FROM\s+([^\s]+)') {
                $imageRef = $matches[1]
            }

            if ($imageRef -and $imageRef.StartsWith('$')) {
                continue
            }

            if ($imageRef -and (Test-ImageReferenceMutable -Reference $imageRef)) {
                $findings.Add([pscustomobject]@{
                    Path = $file.FullName
                    Line = $lineNumber
                    Image = $imageRef
                    Reason = "latest/stable/tagless"
                }) | Out-Null
            } elseif ($imageRef -and (Test-ImageReferenceMissingDigest -Reference $imageRef)) {
                $findings.Add([pscustomobject]@{
                    Path = $file.FullName
                    Line = $lineNumber
                    Image = $imageRef
                    Reason = "third-party image is not pinned by digest"
                }) | Out-Null
            }
        }
    }
}

if ($findings.Count -gt 0) {
    $messageLines = $findings | ForEach-Object { "$($_.Path):$($_.Line): $($_.Image) ($($_.Reason))" }
    $message = "Mutable image references found:`n$($messageLines -join [Environment]::NewLine)"
    if ($FailOnMutableTags) {
        throw $message
    }
    Write-Warning $message
} else {
    Write-Host "K3s image policy checks passed."
}
