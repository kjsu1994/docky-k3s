param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "production",
    [string]$Root = "C:\K3s",
    [string]$Kubeconfig = "C:\K3s\runtime\kubeconfig.yml",
    [string]$BackupPath = "C:\K3s\backups\<timestamp>",
    [string]$ReleaseTag = "<release-tag>",
    [string]$BaseUrl,
    [string]$OutputRoot = "C:\K3s\runtime\runbooks",
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$UseComposeFrontendCurrent,
    [switch]$RestoreRedis,
    [switch]$AllowEmptyRedis
)

$ErrorActionPreference = "Stop"

function New-CodeBlock {
    param([Parameter(Mandatory = $true)][string]$Text)
    $nl = [Environment]::NewLine
    return "~~~powershell$nl$Text$nl~~~"
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = switch ($Environment) {
        "docker-desktop" { "http://localhost:8080" }
        "staging" { "https://staging.docky.co.kr" }
        default { "https://docky.co.kr" }
    }
}

$resolvedRoot = (Resolve-Path $Root).Path
$templatePath = Join-Path $resolvedRoot "templates\cutover-runbook.ko.md"
if (-not (Test-Path $templatePath)) {
    throw "Runbook template not found: $templatePath"
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot "runtime")).TrimEnd('\')
if (-not ($resolvedOutputRoot.Equals($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputRoot.StartsWith($runtimeRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputRoot must stay under C:\K3s\runtime: $resolvedOutputRoot"
}
if (-not (Test-Path $resolvedOutputRoot)) {
    New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null
}

$nl = [Environment]::NewLine
$line = [char]96
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputPath = Join-Path $resolvedOutputRoot "cutover-$Environment-$stamp.md"

$cloudflaredApplyFlag = if ($IncludeCloudflared) { " $line$nl  -IncludeCloudflared" } else { "" }
$cloudflaredPostFlag = if ($IncludeCloudflared) { " $line$nl  -IncludeCloudflared" } else { "" }
$bootstrapApplyFlag = if ($BootstrapMinio) { " $line$nl  -BootstrapMinio" } else { "" }
$allowEmptyRedisFlag = if ($AllowEmptyRedis) { " $line$nl  -AllowEmptyRedis" } else { "" }
$requireRegistryFlag = if ($Environment -eq "docker-desktop") { "" } else { " $line$nl  -RequireRegistryAvailability" }
$skipGhcrSecretFlag = if ($Environment -eq "docker-desktop") { " $line$nl  -SkipGhcrSecret" } else { "" }

if ($ReleaseTag -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
    throw "Invalid release tag: $ReleaseTag"
}
if ($Environment -ne "docker-desktop" -and $ReleaseTag -match '^(replace-me|latest|stable)$|^(local|dev|test|tmp|scratch)[_.-]|(compose-current|validator|verify|wip)') {
    throw "Production/staging runbooks require an immutable release tag, not: $ReleaseTag"
}

$frontendLines = @()
if ($UseComposeFrontendCurrent) {
    $frontendLines += @(
        "C:\K3s\scripts\Test-K3sFrontendStaticSource.ps1 $line",
        "  -DistPath C:\compose\minio-data\client\current",
        ""
    )
}

if ($Environment -eq "docker-desktop") {
    $frontendLines += "C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 $line"
    if ($UseComposeFrontendCurrent) {
        $frontendLines += "  -Tag $ReleaseTag $line"
        $frontendLines += "  -UseComposeFrontendCurrent"
    } else {
        $frontendLines += "  -Tag $ReleaseTag"
    }
    $frontendLines += ""
    $frontendLines += "C:\K3s\scripts\Set-K3sImageTags.ps1 $line"
    $frontendLines += "  -BackendTag $ReleaseTag $line"
    $frontendLines += "  -FrontendTag $ReleaseTag $line"
    $frontendLines += "  -KustomizationPath C:\K3s\overlays\docker-desktop\kustomization.yml"
} else {
    $frontendLines += "C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 $line"
    $frontendLines += "  -Tag $ReleaseTag $line"
    if ($UseComposeFrontendCurrent) {
        $frontendLines += "  -UseComposeFrontendCurrent $line"
    }
    $frontendLines += "  -Push $line"
    $frontendLines += "  -UpdateManifests"
}
$frontendBuildCommand = $frontendLines -join $nl

$redisRestoreBlock = ""
if ($RestoreRedis) {
    $redisRestoreCommand = @(
        "C:\K3s\scripts\Invoke-K3sRedisRestore.ps1 $line",
        "  -RdbPath $BackupPath\redis\docky-redis-<timestamp>.rdb $line",
        "  -Kubeconfig $Kubeconfig $line",
        "  -ReplaceExisting $line",
        "  -ConfirmRestore"
    ) -join $nl
    $redisRestoreBlock = New-CodeBlock -Text $redisRestoreCommand
}

$completionBlock = ""
if ($Environment -eq "production") {
    $completionCommand = @(
        "C:\K3s\scripts\Test-K3sCompletionGate.ps1 $line",
        "  -Kubeconfig $Kubeconfig $line",
        "  -BackupPath $BackupPath $line",
        "  -BaseUrl $BaseUrl$cloudflaredPostFlag$bootstrapApplyFlag$allowEmptyRedisFlag",
        "",
        "C:\K3s\scripts\New-K3sExplanation.ps1 $line",
        "  -Kubeconfig $Kubeconfig $line",
        "  -BackupPath $BackupPath $line",
        "  -BaseUrl $BaseUrl$cloudflaredPostFlag$bootstrapApplyFlag$allowEmptyRedisFlag"
    ) -join $nl
    $completionBlock = New-CodeBlock -Text $completionCommand
}

$template = Get-Content -Raw -Encoding UTF8 -LiteralPath $templatePath
$content = $template.
    Replace("__CREATED_AT__", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")).
    Replace("__ENVIRONMENT__", $Environment).
    Replace("__BASE_URL__", $BaseUrl).
    Replace("__KUBECONFIG__", $Kubeconfig).
    Replace("__BACKUP_PATH__", $BackupPath).
    Replace("__RELEASE_TAG__", $ReleaseTag).
    Replace("__FRONTEND_BUILD_COMMAND__", $frontendBuildCommand).
    Replace("__CLOUDFLARED_APPLY_FLAG__", $cloudflaredApplyFlag).
    Replace("__CLOUDFLARED_POST_FLAG__", $cloudflaredPostFlag).
    Replace("__BOOTSTRAP_APPLY_FLAG__", $bootstrapApplyFlag).
    Replace("__ALLOW_EMPTY_REDIS_FLAG__", $allowEmptyRedisFlag).
    Replace("__REQUIRE_REGISTRY_FLAG__", $requireRegistryFlag).
    Replace("__SKIP_GHCR_SECRET_FLAG__", $skipGhcrSecretFlag).
    Replace("__REDIS_RESTORE_BLOCK__", $redisRestoreBlock).
    Replace("__COMPLETION_BLOCK__", $completionBlock)

$nonDockerPattern = '(?s)<!-- non-docker-start -->\r?\n?(.*?)\r?\n?<!-- non-docker-end -->'
if ($Environment -eq "docker-desktop") {
    $content = [regex]::Replace($content, $nonDockerPattern, "")
} else {
    $content = [regex]::Replace($content, $nonDockerPattern, '$1')
}
$content = [regex]::Replace($content, "(\r?\n){3,}", "$nl$nl")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outputPath, $content + [Environment]::NewLine, $utf8NoBom)
Write-Host "K3s cutover runbook written: $outputPath"
