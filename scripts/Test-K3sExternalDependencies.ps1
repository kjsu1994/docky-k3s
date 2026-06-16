param(
    [string]$Root = "C:\K3s",
    [ValidateSet("all", "production", "staging", "docker-desktop")]
    [string]$Environment = "all",
    [switch]$FailOnUnresolved
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$roots = switch ($Environment) {
    "production" { @((Join-Path $Root "manifests")) }
    "staging" { @((Join-Path $Root "overlays\staging")) }
    "docker-desktop" { @((Join-Path $Root "overlays\docker-desktop")) }
    default {
        @(
            (Join-Path $Root "manifests"),
            (Join-Path $Root "overlays\staging"),
            (Join-Path $Root "overlays\docker-desktop")
        )
    }
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

function Get-ConfigValue {
    param([string]$Text, [string]$Name)

    $pattern = '(?m)^\s+' + [regex]::Escape($Name) + ':\s+["'']?([^"''\s]+)["'']?\s*$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

$findings = New-Object System.Collections.Generic.List[string]
foreach ($manifestRoot in $roots) {
    if (-not (Test-Path $manifestRoot)) {
        throw "Manifest root not found: $manifestRoot"
    }

    $rendered = & kubectl kustomize $manifestRoot
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl kustomize failed: $manifestRoot"
    }
    $renderedText = $rendered -join [Environment]::NewLine
    $leaf = Split-Path -Leaf $manifestRoot

    $ollamaEnabled = (Get-ConfigValue -Text $renderedText -Name "OLLAMA_ENABLED") -eq "true"
    if (-not $ollamaEnabled) {
        continue
    }

    $ollamaBaseUrl = Get-ConfigValue -Text $renderedText -Name "OLLAMA_BASE_URL"
    if ([string]::IsNullOrWhiteSpace($ollamaBaseUrl)) {
        $findings.Add("${leaf}: OLLAMA_ENABLED=true but OLLAMA_BASE_URL is missing.")
        continue
    }

    if ($ollamaBaseUrl -eq "http://ollama:11435") {
        if ($renderedText -notmatch '(?ms)kind:\s+Service.*?name:\s+ollama\b') {
            $findings.Add("${leaf}: OLLAMA_BASE_URL points to in-cluster ollama service, but Service/ollama was not rendered.")
        }
        if ($renderedText -notmatch '(?ms)kind:\s+StatefulSet.*?name:\s+ollama\b') {
            $findings.Add("${leaf}: OLLAMA_BASE_URL points to in-cluster ollama service, but StatefulSet/ollama was not rendered.")
        }
        continue
    }

    $findings.Add("${leaf}: unexpected OLLAMA_BASE_URL for K3s cutover: $ollamaBaseUrl")
}

if ($findings.Count -gt 0) {
    $message = "External dependency findings:`n$($findings -join [Environment]::NewLine)"
    if ($FailOnUnresolved) {
        throw $message
    }
    Write-Warning $message
} else {
    Write-Host "K3s external dependency checks passed."
}
