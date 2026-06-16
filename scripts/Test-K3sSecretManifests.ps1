param(
    [string]$DockySecretPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$GhcrSecretPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [switch]$SkipGhcrSecret
)

$ErrorActionPreference = "Stop"

function Assert-FileClean {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredPatterns,
        [string[]]$ForbiddenPatterns = @()
    )
    if (-not (Test-Path $Path)) {
        throw "Secret manifest not found: $Path"
    }
    $text = Get-Content -Raw -Path $Path
    if ($text -match "replace-me") {
        throw "Secret manifest still contains placeholder value: $Path"
    }
    foreach ($pattern in $RequiredPatterns) {
        if ($text -notmatch $pattern) {
            throw "Secret manifest missing required pattern '$pattern': $Path"
        }
    }
    foreach ($pattern in $ForbiddenPatterns) {
        if ($text -match $pattern) {
            throw "Secret manifest contains forbidden config key '$pattern': $Path"
        }
    }
}

Assert-FileClean -Path $DockySecretPath -RequiredPatterns @(
    "kind:\s+Secret",
    "name:\s+docky-secret",
    "CLOUDFLARE_TUNNEL_TOKEN:",
    "ORACLE_PASSWORD:",
    "SPRING_DATASOURCE_USERNAME:",
    "SPRING_DATASOURCE_PASSWORD:",
    "JWT_SECRET_KEY:",
    "S3_ACCESS_KEY:",
    "S3_SECRET_KEY:",
    "DART_API_KEY:",
    "KIS_APP_KEY:",
    "KIS_APP_SECRET:",
    "MAIL_ADDRESS_MASTER:",
    "SMTP_HOST:",
    "SMTP_USERNAME:",
    "SMTP_PASSWORD:"
) -ForbiddenPatterns @(
    "APP_CORS_ALLOWED_ORIGIN_PATTERNS:",
    "GOOGLE_REDIRECT_URI:",
    "NAVER_REDIRECT_URI:",
    "S3_ENDPOINT:",
    "S3_PRESIGNED_PUBLIC_ENDPOINT:",
    "SPRING_PROFILES_ACTIVE:",
    "SPRING_DATA_REDIS_HOST:",
    "SPRING_DATA_REDIS_PORT:",
    "PARKING_CSV_PATH:",
    "RESTROOM_CSV_PATH:",
    "LIBRARY_CSV_PATH:",
    "BUNKER_CSV_PATH:",
    "MEDICAL_CSV_PATH:",
    "MEDICAL_LOCATION_CSV_PATH:",
    "STREAMING_STORAGE_ROOT:",
    "OLLAMA_ENABLED:",
    "KIS_ENABLED:"
)

if (-not $SkipGhcrSecret) {
    Assert-FileClean -Path $GhcrSecretPath -RequiredPatterns @(
        "kind:\s+Secret",
        "name:\s+ghcr-pull-secret",
        "kubernetes\.io/dockerconfigjson"
    )
}

Write-Host "Secret manifest checks passed."
