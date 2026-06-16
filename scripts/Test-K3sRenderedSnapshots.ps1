param(
    [string]$Root = "C:\K3s",
    [ValidateSet("all", "production", "staging", "docker-desktop")]
    [string]$Environment = "all",
    [switch]$RequireSnapshot,
    [switch]$FailOnPlaceholderImages
)

$ErrorActionPreference = "Stop"

function Read-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Assert-Snapshot {
    param(
        [Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedEnvironment,
        [switch]$FailOnPlaceholderImages
    )

    $metadataPath = Join-Path $Snapshot.FullName "metadata.json"
    if (-not (Test-Path $metadataPath)) {
        throw "Rendered snapshot is missing metadata.json: $($Snapshot.FullName)"
    }

    $metadata = Read-Utf8Text -Path $metadataPath | ConvertFrom-Json
    if ($metadata.environment -ne $ExpectedEnvironment) {
        throw "Rendered snapshot metadata environment mismatch. expected=$ExpectedEnvironment actual=$($metadata.environment) path=$($Snapshot.FullName)"
    }
    if (-not $metadata.outputDir -or -not ([string]$metadata.outputDir).Equals($Snapshot.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Rendered snapshot metadata outputDir does not match snapshot path: $($Snapshot.FullName)"
    }

    foreach ($name in @("metadata.json", "ingress-nginx.yml", "app-$ExpectedEnvironment.yml")) {
        $path = Join-Path $Snapshot.FullName $name
        if (-not (Test-Path $path)) {
            throw "Rendered snapshot is missing required file ${name}: $($Snapshot.FullName)"
        }
        if ((Get-Item -LiteralPath $path).Length -le 0) {
            throw "Rendered snapshot file is empty: $path"
        }
    }

    $allText = ""
    foreach ($manifest in Get-ChildItem -LiteralPath $Snapshot.FullName -File -Filter "*.yml") {
        $allText += [Environment]::NewLine + (Read-Utf8Text -Path $manifest.FullName)
    }

    $composeRootText = "C:\com" + "pose"
    $registryExampleText = "registry." + "example.com"
    foreach ($forbidden in @("kind: Secret", $composeRootText, $registryExampleText)) {
        if ($allText.Contains($forbidden)) {
            throw "Rendered snapshot contains forbidden content '$forbidden': $($Snapshot.FullName)"
        }
    }

    if ($FailOnPlaceholderImages -and $allText -match 'replace-me') {
        throw "Rendered snapshot still contains placeholder image tag: $($Snapshot.FullName)"
    }

    switch ($ExpectedEnvironment) {
        "production" {
            foreach ($required in @("host: docky.co.kr", "host: www.docky.co.kr", "S3_PRESIGNED_PUBLIC_ENDPOINT: https://docky.co.kr")) {
                if (-not $allText.Contains($required)) {
                    throw "Production rendered snapshot missing required content '$required': $($Snapshot.FullName)"
                }
            }
            foreach ($blocked in @("host: staging.docky.co.kr", "host: localhost", "host.docker.internal")) {
                if ($allText.Contains($blocked)) {
                    throw "Production rendered snapshot contains environment leakage '$blocked': $($Snapshot.FullName)"
                }
            }
        }
        "staging" {
            foreach ($required in @("host: staging.docky.co.kr", "S3_PRESIGNED_PUBLIC_ENDPOINT: https://staging.docky.co.kr")) {
                if (-not $allText.Contains($required)) {
                    throw "Staging rendered snapshot missing required content '$required': $($Snapshot.FullName)"
                }
            }
            foreach ($blocked in @("host: docky.co.kr", "host: www.docky.co.kr", "host: localhost", "host.docker.internal")) {
                if ($allText.Contains($blocked)) {
                    throw "Staging rendered snapshot contains environment leakage '$blocked': $($Snapshot.FullName)"
                }
            }
        }
        "docker-desktop" {
            foreach ($required in @("host: localhost", "S3_PRESIGNED_PUBLIC_ENDPOINT: http://localhost:8080", "OLLAMA_BASE_URL: http://ollama:11435", "ghcr-pull-secret")) {
                if (-not $allText.Contains($required)) {
                    throw "Docker Desktop rendered snapshot missing required content '$required': $($Snapshot.FullName)"
                }
            }
        }
    }
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$renderRoot = Join-Path $Root "runtime\rendered"
if (-not (Test-Path $renderRoot)) {
    if ($RequireSnapshot) {
        throw "Rendered snapshot root not found: $renderRoot"
    }
    Write-Host "No rendered snapshot root found: $renderRoot"
    return
}

$environments = if ($Environment -eq "all") {
    @("production", "staging", "docker-desktop")
} else {
    @($Environment)
}

$validated = New-Object System.Collections.Generic.List[string]
foreach ($environmentName in $environments) {
    $snapshots = @(Get-ChildItem -LiteralPath $renderRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Where-Object {
            $metadataPath = Join-Path $_.FullName "metadata.json"
            if (-not (Test-Path $metadataPath)) {
                return $false
            }
            $metadata = Read-Utf8Text -Path $metadataPath | ConvertFrom-Json
            return $metadata.environment -eq $environmentName
        })

    if ($snapshots.Count -eq 0) {
        if ($RequireSnapshot) {
            throw "No rendered snapshot found for $environmentName under $renderRoot"
        }
        continue
    }

    $latest = $snapshots | Select-Object -First 1
    Assert-Snapshot -Snapshot $latest -ExpectedEnvironment $environmentName -FailOnPlaceholderImages:$FailOnPlaceholderImages
    $validated.Add($latest.FullName) | Out-Null
}

Write-Host "K3s rendered snapshot checks passed."
foreach ($path in $validated) {
    Write-Host "Snapshot: $path"
}
