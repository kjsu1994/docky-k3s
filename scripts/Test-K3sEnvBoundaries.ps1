param(
    [string]$Root = "C:\K3s"
)

$ErrorActionPreference = "Stop"

$appConfigPath = Join-Path $Root "manifests\config\app-config.yml"
$secretTemplatePath = Join-Path $Root "manifests\secrets\docky-secret.template.yml"
$secretGeneratorPath = Join-Path $Root "scripts\New-DockySecretFromEnv.ps1"

foreach ($path in @($appConfigPath, $secretTemplatePath, $secretGeneratorPath)) {
    if (-not (Test-Path $path)) {
        throw "Required env boundary file missing: $path"
    }
}

$appConfig = Get-Content -Raw -Path $appConfigPath
$secretTemplate = Get-Content -Raw -Path $secretTemplatePath
$secretGenerator = Get-Content -Raw -Path $secretGeneratorPath

$requiredConfigKeys = @(
    "SPRING_PROFILES_ACTIVE",
    "APP_CORS_ALLOWED_ORIGIN_PATTERNS",
    "SPRING_DATASOURCE_URL",
    "SPRING_DATA_REDIS_HOST",
    "SPRING_DATA_REDIS_PORT",
    "S3_ENDPOINT",
    "S3_PRESIGNED_PUBLIC_ENDPOINT",
    "GOOGLE_REDIRECT_URI",
    "NAVER_REDIRECT_URI",
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
    "OLLAMA_ENABLED",
    "OLLAMA_BASE_URL",
    "OLLAMA_CHAT_MODEL",
    "OLLAMA_VISION_MODEL",
    "OLLAMA_CONNECT_TIMEOUT_MS",
    "OLLAMA_READ_TIMEOUT_MS",
    "OLLAMA_MAX_IMAGE_BYTES",
    "OLLAMA_MAX_IMAGES_PER_REQUEST",
    "KIS_ENABLED",
    "KIS_MOCK"
)

$requiredSecretKeys = @(
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

$forbiddenSecretConfigKeys = @(
    "APP_CORS_ALLOWED_ORIGIN_PATTERNS",
    "GOOGLE_REDIRECT_URI",
    "NAVER_REDIRECT_URI",
    "S3_ENDPOINT",
    "S3_PRESIGNED_PUBLIC_ENDPOINT",
    "SPRING_PROFILES_ACTIVE",
    "SPRING_DATA_REDIS_HOST",
    "SPRING_DATA_REDIS_PORT",
    "PARKING_CSV_PATH",
    "RESTROOM_CSV_PATH",
    "LIBRARY_CSV_PATH",
    "BUNKER_CSV_PATH",
    "MEDICAL_CSV_PATH",
    "MEDICAL_LOCATION_CSV_PATH",
    "STREAMING_STORAGE_ROOT",
    "OLLAMA_ENABLED",
    "KIS_ENABLED"
)

$forbiddenConfigSecretKeys = @(
    "CLOUDFLARE_TUNNEL_TOKEN",
    "ORACLE_PASSWORD",
    "ORACLE_APP_USER_PASSWORD",
    "SPRING_DATASOURCE_PASSWORD",
    "MINIO_ROOT_PASSWORD",
    "S3_ACCESS_KEY",
    "S3_SECRET_KEY",
    "JWT_SECRET_KEY",
    "GOOGLE_CLIENT_SECRET",
    "NAVER_CLIENT_SECRET",
    "NAVER_OPENAPI_CLIENT_SECRET",
    "NAVER_MAP_CLIENT_SECRET",
    "SMTP_PASSWORD",
    "DART_API_KEY",
    "KIS_APP_SECRET"
)

foreach ($key in $requiredConfigKeys) {
    if ($appConfig -notmatch "(?m)^\s+$([regex]::Escape($key))\s*:") {
        throw "ConfigMap missing required key: $key"
    }
}

foreach ($key in $requiredSecretKeys) {
    if ($secretTemplate -notmatch "(?m)^\s+$([regex]::Escape($key))\s*:") {
        throw "Secret template missing required key: $key"
    }
    if ($secretGenerator -notmatch "`"$([regex]::Escape($key))`"") {
        throw "Secret generator missing required allowlist key: $key"
    }
}

foreach ($key in $forbiddenSecretConfigKeys) {
    if ($secretTemplate -match "(?m)^\s+$([regex]::Escape($key))\s*:") {
        throw "Secret template contains config-owned key: $key"
    }
}

foreach ($key in $forbiddenConfigSecretKeys) {
    if ($appConfig -match "(?m)^\s+$([regex]::Escape($key))\s*:") {
        throw "ConfigMap contains secret-owned key: $key"
    }
}

Write-Host "K3s environment boundary checks passed."
