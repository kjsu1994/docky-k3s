param(
    [string]$Root = "C:\K3s",
    [string]$ComposeEnvPath = "C:\compose\.env",
    [switch]$FailOnMismatch,
    [string]$ExpectedOllamaModel = "qwen3.5:2b-q4_K_M"
)

$ErrorActionPreference = "Stop"

function Import-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
            continue
        }
        $parts = $trimmed.Split("=", 2)
        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}

function Import-ConfigMapData {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = @{}
    $inData = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^data:\s*$') {
            $inData = $true
            continue
        }
        if (-not $inData) {
            continue
        }
        if ($line -match '^\S') {
            break
        }
        if ($line -match '^\s{2}([A-Za-z0-9_]+):\s*(.*)\s*$') {
            $key = $matches[1]
            $value = $matches[2].Trim()
            if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $result[$key] = $value
        }
    }
    return $result
}

function Normalize-ComparableValue {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }
    $trimmed = $Value.Trim()
    if ($trimmed -match '^(true|false)$') {
        return $trimmed.ToLowerInvariant()
    }
    return $trimmed
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}
if (-not (Test-Path $ComposeEnvPath)) {
    throw "Compose env not found: $ComposeEnvPath"
}
$resolvedComposeEnv = (Resolve-Path $ComposeEnvPath).Path
if (-not $resolvedComposeEnv.Equals("C:\compose\.env", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Compose env path must remain C:\compose\.env for this parity check: $resolvedComposeEnv"
}

$appConfigPath = Join-Path $Root "manifests\config\app-config.yml"
if (-not (Test-Path $appConfigPath)) {
    throw "K3s app ConfigMap not found: $appConfigPath"
}

$composeEnv = Import-EnvFile -Path $resolvedComposeEnv
$k3sConfig = Import-ConfigMapData -Path $appConfigPath

$parityKeys = @(
    "SMTP_PORT",
    "SMTP_AUTH",
    "SMTP_STARTTLS_ENABLE",
    "SIGNUP_EMAIL_VERIFICATION_EXPIRE_MINUTES",
    "PARKING_CSV_PATH",
    "RESTROOM_CSV_PATH",
    "LIBRARY_CSV_PATH",
    "BUNKER_CSV_PATH",
    "MEDICAL_CSV_PATH",
    "MEDICAL_LOCATION_CSV_PATH",
    "MEDICAL_GEOCODE_MAX_API_CALLS_PER_IMPORT",
    "STREAMING_STORAGE_ROOT",
    "STREAMING_FFMPEG_BINARY",
    "STREAMING_FFPROBE_BINARY",
    "KIS_ENABLED",
    "KIS_MOCK",
    "OLLAMA_ENABLED",
    "OLLAMA_CONNECT_TIMEOUT_MS",
    "OLLAMA_READ_TIMEOUT_MS",
    "OLLAMA_MAX_IMAGE_BYTES",
    "OLLAMA_MAX_IMAGES_PER_REQUEST"
)

$findings = New-Object System.Collections.Generic.List[object]
foreach ($key in $parityKeys) {
    if (-not $composeEnv.ContainsKey($key)) {
        continue
    }
    if (-not $k3sConfig.ContainsKey($key)) {
        $findings.Add([pscustomobject]@{
            Key = $key
            Status = "FAIL"
            Detail = "K3s ConfigMap is missing a non-secret Compose parity key."
        }) | Out-Null
        continue
    }

    $composeValue = Normalize-ComparableValue -Value $composeEnv[$key]
    $k3sValue = Normalize-ComparableValue -Value $k3sConfig[$key]
    if ($composeValue -ne $k3sValue) {
        $findings.Add([pscustomobject]@{
            Key = $key
            Status = "FAIL"
            Detail = "Compose and K3s values differ."
        }) | Out-Null
    } else {
        $findings.Add([pscustomobject]@{
            Key = $key
            Status = "PASS"
            Detail = "Matches Compose non-secret setting."
        }) | Out-Null
    }
}


foreach ($key in @("OLLAMA_CHAT_MODEL", "OLLAMA_VISION_MODEL")) {
    if (-not $k3sConfig.ContainsKey($key)) {
        $findings.Add([pscustomobject]@{
            Key = $key
            Status = "FAIL"
            Detail = "K3s ConfigMap is missing the required Ollama model key."
        }) | Out-Null
        continue
    }

    $k3sValue = Normalize-ComparableValue -Value $k3sConfig[$key]
    if ($k3sValue -ne $ExpectedOllamaModel) {
        $findings.Add([pscustomobject]@{
            Key = $key
            Status = "FAIL"
            Detail = "Expected K3s Ollama model $ExpectedOllamaModel, got $k3sValue."
        }) | Out-Null
    } else {
        $findings.Add([pscustomobject]@{
            Key = $key
            Status = "PASS"
            Detail = "Matches intentional K3s Ollama model override."
        }) | Out-Null
    }
}
$findings | Format-Table -AutoSize

$failures = @($findings | Where-Object { $_.Status -eq "FAIL" })
if ($failures.Count -gt 0) {
    if ($FailOnMismatch) {
        throw "K3s Compose parity check failed."
    }
    Write-Warning "K3s Compose parity check has findings. Pass -FailOnMismatch to fail on them."
} else {
    Write-Host "K3s Compose parity checks passed."
}
