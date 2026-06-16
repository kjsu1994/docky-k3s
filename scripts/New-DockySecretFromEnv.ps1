param(
    [Parameter(Mandatory = $true)]
    [string]$EnvPath,
    [string]$ExtraEnvPath = "C:\secret\docky-k3s-extra.env",
    [string]$OutputPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$Namespace = "docky",
    [string]$SecretName = "docky-secret",
    [string]$CloudflareTunnelToken,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

function Import-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Target
    )

    if (-not (Test-Path $Path)) {
        throw "Env file not found: $Path"
    }

    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') {
            continue
        }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) {
            throw "Invalid env line in ${Path}: $line"
        }
        $key = $parts[0].Trim()
        $value = $parts[1]
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $Target[$key] = $value
    }
}

function Assert-PathUnder {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if (-not ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "${Message}: $candidateFull"
    }
}

$requiredKeys = @(
    "CLOUDFLARE_TUNNEL_TOKEN",
    "ORACLE_PASSWORD",
    "ORACLE_APP_USER",
    "ORACLE_APP_USER_PASSWORD",
    "SPRING_DATASOURCE_USERNAME",
    "SPRING_DATASOURCE_PASSWORD",
    "MINIO_ROOT_USER",
    "MINIO_ROOT_PASSWORD",
    "S3_ACCESS_KEY",
    "S3_SECRET_KEY",
    "JWT_SECRET_KEY",
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "NAVER_CLIENT_ID",
    "NAVER_CLIENT_SECRET",
    "NAVER_OPENAPI_CLIENT_ID",
    "NAVER_OPENAPI_CLIENT_SECRET",
    "NAVER_MAP_CLIENT_ID",
    "NAVER_MAP_CLIENT_SECRET",
    "MAIL_ADDRESS_MASTER",
    "SMTP_HOST",
    "SMTP_USERNAME",
    "SMTP_PASSWORD",
    "DART_API_KEY",
    "KIS_APP_KEY",
    "KIS_APP_SECRET"
)

$optionalSecretKeys = @()

$values = [ordered]@{}
$resolvedEnvPath = (Resolve-Path $EnvPath).Path
if (-not $resolvedEnvPath.Equals("C:\compose\.env", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "EnvPath must remain the read-only Compose env source C:\compose\.env: $resolvedEnvPath"
}
Import-EnvFile -Path $resolvedEnvPath -Target $values

if (-not [string]::IsNullOrWhiteSpace($ExtraEnvPath)) {
    $defaultExtraEnvPath = "C:\secret\docky-k3s-extra.env"
    $legacyExtraEnvPath = "C:\secure\docky-k3s-extra.env"
    $usingDefaultExtraEnvPath = -not $PSBoundParameters.ContainsKey("ExtraEnvPath")
    $candidateExtraEnvPath = $ExtraEnvPath

    if ($usingDefaultExtraEnvPath -and -not (Test-Path $candidateExtraEnvPath) -and (Test-Path $legacyExtraEnvPath)) {
        $candidateExtraEnvPath = $legacyExtraEnvPath
        Write-Warning "Default extra env was not found. Falling back to legacy path: $legacyExtraEnvPath"
    }

    if (-not (Test-Path $candidateExtraEnvPath)) {
        if ($usingDefaultExtraEnvPath) {
            Write-Warning "ExtraEnvPath not found yet: $candidateExtraEnvPath"
        } else {
            throw "ExtraEnvPath not found: $candidateExtraEnvPath"
        }
    } else {
        $resolvedExtraEnvPath = (Resolve-Path $candidateExtraEnvPath).Path
        $composeRoot = [System.IO.Path]::GetFullPath("C:\compose").TrimEnd('\')
        if ($resolvedExtraEnvPath.Equals($composeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolvedExtraEnvPath.StartsWith($composeRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "ExtraEnvPath must not be stored under C:\compose: $resolvedExtraEnvPath"
        }
        $k3sRoot = [System.IO.Path]::GetFullPath("C:\K3s").TrimEnd('\')
        if ($resolvedExtraEnvPath.Equals($k3sRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolvedExtraEnvPath.StartsWith($k3sRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "ExtraEnvPath must not be stored under C:\K3s: $resolvedExtraEnvPath"
        }
        Import-EnvFile -Path $resolvedExtraEnvPath -Target $values
    }
}

if (-not [string]::IsNullOrWhiteSpace($CloudflareTunnelToken)) {
    $values["CLOUDFLARE_TUNNEL_TOKEN"] = $CloudflareTunnelToken
}

$missing = $requiredKeys | Where-Object { -not $values.Contains($_) -or [string]::IsNullOrWhiteSpace($values[$_]) }
if ($missing) {
    throw "Missing required secret keys: $($missing -join ', ')"
}

if ($values["ORACLE_APP_USER"] -ne $values["SPRING_DATASOURCE_USERNAME"]) {
    throw "ORACLE_APP_USER must match SPRING_DATASOURCE_USERNAME for the in-cluster Oracle app user."
}

if ($values["ORACLE_APP_USER_PASSWORD"] -ne $values["SPRING_DATASOURCE_PASSWORD"]) {
    throw "ORACLE_APP_USER_PASSWORD must match SPRING_DATASOURCE_PASSWORD for the in-cluster Oracle app user."
}

if ($values["JWT_SECRET_KEY"].Length -lt 32) {
    throw "JWT_SECRET_KEY must be at least 32 characters."
}

if ($ValidateOnly) {
    Write-Host "Secret source validation passed. Output not written."
    return
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
Assert-PathUnder -Candidate $resolvedOutputPath -AllowedRoot "C:\K3s\runtime" -Message "OutputPath must stay under C:\K3s\runtime"
$outputDir = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("apiVersion: v1")
$lines.Add("kind: Secret")
$lines.Add("metadata:")
$lines.Add("  name: $SecretName")
$lines.Add("  namespace: $Namespace")
$lines.Add("type: Opaque")
$lines.Add("stringData:")

$secretKeys = New-Object System.Collections.Generic.List[string]
foreach ($key in $requiredKeys) {
    $secretKeys.Add($key)
}
foreach ($key in $optionalSecretKeys) {
    if ($values.Contains($key) -and -not [string]::IsNullOrWhiteSpace($values[$key])) {
        $secretKeys.Add($key)
    }
}

foreach ($key in $secretKeys) {
    $escaped = $values[$key].Replace("'", "''")
    $lines.Add("  ${key}: '$escaped'")
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedOutputPath, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, $utf8NoBom)
Write-Host "Wrote secret manifest: $resolvedOutputPath"
