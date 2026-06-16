param(
    [string]$EnvPath = "C:\compose\.env",
    [string]$ExtraEnvPath = "C:\secret\docky-k3s-extra.env",
    [string]$CloudflareTunnelToken,
    [switch]$RequireExtraEnv,
    [switch]$RequireAllKeys
)

$ErrorActionPreference = "Stop"

function Import-EnvKeyMap {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Env file not found: $Path"
    }

    $map = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') {
            continue
        }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) {
            throw "Invalid env line in ${Path}: $line"
        }
        $key = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw "Invalid empty env key in ${Path}."
        }
        $map[$key] = $parts[1]
    }
    return $map
}

function Assert-ExactPath {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $candidateFull = (Resolve-Path $Candidate).Path
    $expectedFull = [System.IO.Path]::GetFullPath($Expected)
    if (-not $candidateFull.Equals($expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "${Message}: $candidateFull"
    }
    return $candidateFull
}

function Assert-NotUnder {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$ForbiddenRoot,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($ForbiddenRoot).TrimEnd('\')
    if ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
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

$resolvedEnvPath = Assert-ExactPath -Candidate $EnvPath -Expected "C:\compose\.env" -Message "EnvPath must remain the read-only Compose env source"
$values = [ordered]@{}
$composeValues = Import-EnvKeyMap -Path $resolvedEnvPath
foreach ($key in $composeValues.Keys) {
    $values[$key] = $composeValues[$key]
}

$defaultExtraEnvPath = "C:\secret\docky-k3s-extra.env"
$legacyExtraEnvPath = "C:\secure\docky-k3s-extra.env"
$usingDefaultExtraEnvPath = -not $PSBoundParameters.ContainsKey("ExtraEnvPath")
$candidateExtraEnvPath = $ExtraEnvPath
if ($usingDefaultExtraEnvPath -and -not (Test-Path $candidateExtraEnvPath) -and (Test-Path $legacyExtraEnvPath)) {
    $candidateExtraEnvPath = $legacyExtraEnvPath
    Write-Warning "Default extra env was not found. Falling back to legacy path: $legacyExtraEnvPath"
}

$extraExists = Test-Path $candidateExtraEnvPath
if ($extraExists) {
    $resolvedExtraEnvPath = (Resolve-Path $candidateExtraEnvPath).Path
    Assert-NotUnder -Candidate $resolvedExtraEnvPath -ForbiddenRoot "C:\compose" -Message "ExtraEnvPath must not be stored under C:\compose"
    Assert-NotUnder -Candidate $resolvedExtraEnvPath -ForbiddenRoot "C:\K3s" -Message "ExtraEnvPath must not be stored under C:\K3s"
    $extraValues = Import-EnvKeyMap -Path $resolvedExtraEnvPath
    foreach ($key in $extraValues.Keys) {
        $values[$key] = $extraValues[$key]
    }
} elseif ($RequireExtraEnv) {
    throw "ExtraEnvPath is required but not found: $candidateExtraEnvPath"
} else {
    Write-Warning "ExtraEnvPath not found yet: $candidateExtraEnvPath"
}

if (-not [string]::IsNullOrWhiteSpace($CloudflareTunnelToken)) {
    $values["CLOUDFLARE_TUNNEL_TOKEN"] = $CloudflareTunnelToken
}

$missing = $requiredKeys | Where-Object { -not $values.Contains($_) -or [string]::IsNullOrWhiteSpace($values[$_]) }
if ($missing) {
    $message = "Missing required secret source keys: $($missing -join ', ')"
    if ($RequireAllKeys) {
        throw $message
    }
    Write-Warning $message
}

if ($values.Contains("ORACLE_APP_USER") -and $values.Contains("SPRING_DATASOURCE_USERNAME") -and
    -not [string]::IsNullOrWhiteSpace($values["ORACLE_APP_USER"]) -and
    -not [string]::IsNullOrWhiteSpace($values["SPRING_DATASOURCE_USERNAME"]) -and
    $values["ORACLE_APP_USER"] -ne $values["SPRING_DATASOURCE_USERNAME"]) {
    throw "ORACLE_APP_USER must match SPRING_DATASOURCE_USERNAME."
}

if ($values.Contains("ORACLE_APP_USER_PASSWORD") -and $values.Contains("SPRING_DATASOURCE_PASSWORD") -and
    -not [string]::IsNullOrWhiteSpace($values["ORACLE_APP_USER_PASSWORD"]) -and
    -not [string]::IsNullOrWhiteSpace($values["SPRING_DATASOURCE_PASSWORD"]) -and
    $values["ORACLE_APP_USER_PASSWORD"] -ne $values["SPRING_DATASOURCE_PASSWORD"]) {
    throw "ORACLE_APP_USER_PASSWORD must match SPRING_DATASOURCE_PASSWORD."
}

if ($values.Contains("JWT_SECRET_KEY") -and -not [string]::IsNullOrWhiteSpace($values["JWT_SECRET_KEY"]) -and $values["JWT_SECRET_KEY"].Length -lt 32) {
    throw "JWT_SECRET_KEY must be at least 32 characters."
}

Write-Host "Secret source checks passed."
Write-Host "Compose env source: $resolvedEnvPath"
if ($extraExists) {
    Write-Host "Extra env source: $resolvedExtraEnvPath"
} else {
    Write-Host "Extra env source: not found"
}
