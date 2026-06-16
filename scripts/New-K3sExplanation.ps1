param(
    [string]$Root = "C:\K3s",
    [string]$Kubeconfig = "C:\K3s\runtime\kubeconfig.yml",
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    [string]$BaseUrl = "https://docky.co.kr",
    [string]$OutputPath = "C:\K3s\explan.md",
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$AllowEmptyRedis
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

function Get-LatestRenderedSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RenderRoot,
        [Parameter(Mandatory = $true)][string]$Environment
    )

    if (-not (Test-Path $RenderRoot)) {
        throw "Rendered snapshot root not found: $RenderRoot"
    }

    $snapshots = Get-ChildItem -LiteralPath $RenderRoot -Directory |
        Sort-Object LastWriteTime -Descending
    foreach ($snapshot in $snapshots) {
        $metadataPath = Join-Path $snapshot.FullName "metadata.json"
        if (-not (Test-Path $metadataPath)) {
            continue
        }
        $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
        if ($metadata.environment -eq $Environment) {
            return $snapshot
        }
    }

    throw "Rendered snapshot not found for environment ${Environment} under $RenderRoot"
}

function Get-LatestRunbook {
    param(
        [Parameter(Mandatory = $true)][string]$RunbookRoot,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Environment
    )

    if (-not (Test-Path $RunbookRoot)) {
        throw "Runbook root not found: $RunbookRoot"
    }

    $runbook = Get-ChildItem -LiteralPath $RunbookRoot -File -Filter "$Prefix-$Environment-*.md" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $runbook) {
        throw "Runbook not found for ${Prefix}/${Environment} under $RunbookRoot"
    }
    return $runbook
}

$completionArgs = @(
    "-Root", $Root,
    "-Kubeconfig", $Kubeconfig,
    "-BackupPath", $BackupPath,
    "-BaseUrl", $BaseUrl
)
if ($IncludeCloudflared) {
    $completionArgs += "-IncludeCloudflared"
}
if ($BootstrapMinio) {
    $completionArgs += "-BootstrapMinio"
}
if ($AllowEmptyRedis) {
    $completionArgs += "-AllowEmptyRedis"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sCompletionGate.ps1") @completionArgs
if ($LASTEXITCODE -ne 0) {
    throw "Completion gate did not pass. Refusing to write explan.md."
}

$resolvedRoot = (Resolve-Path $Root).Path
$templatePath = Join-Path $resolvedRoot "templates\explan.ko.md"
if (-not (Test-Path $templatePath)) {
    throw "Explanation template not found: $templatePath"
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$resolvedRootForCompare = $resolvedRoot.TrimEnd('\')
if (-not ($resolvedOutputPath.Equals($resolvedRootForCompare, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputPath.StartsWith($resolvedRootForCompare + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputPath must stay under ${resolvedRoot}: $resolvedOutputPath"
}

$renderRoot = Join-Path $Root "runtime\rendered"
$diagnosticsRoot = Join-Path $Root "runtime\diagnostics"
$runbookRoot = Join-Path $Root "runtime\runbooks"
$latestRender = Get-LatestRenderedSnapshot -RenderRoot $renderRoot -Environment "production"
$latestDiagnostics = Get-ChildItem -LiteralPath $diagnosticsRoot -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$latestCutoverRunbook = Get-LatestRunbook -RunbookRoot $runbookRoot -Prefix "cutover" -Environment "production"
$latestRollbackRunbook = Get-LatestRunbook -RunbookRoot $runbookRoot -Prefix "rollback" -Environment "production"

if (-not $latestDiagnostics) {
    throw "Diagnostics snapshot not found under $diagnosticsRoot"
}

$template = Get-Content -Raw -Encoding UTF8 -LiteralPath $templatePath
$content = $template.
    Replace("__CREATED_AT__", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")).
    Replace("__BASE_URL__", $BaseUrl).
    Replace("__BACKUP_PATH__", (Resolve-Path $BackupPath).Path).
    Replace("__LATEST_RENDER__", $latestRender.FullName).
    Replace("__LATEST_DIAGNOSTICS__", $latestDiagnostics.FullName).
    Replace("__LATEST_CUTOVER_RUNBOOK__", $latestCutoverRunbook.FullName).
    Replace("__LATEST_ROLLBACK_RUNBOOK__", $latestRollbackRunbook.FullName).
    Replace("__INCLUDE_CLOUDFLARED__", [string][bool]$IncludeCloudflared).
    Replace("__BOOTSTRAP_MINIO__", [string][bool]$BootstrapMinio)

$outputDir = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedOutputPath, $content + [Environment]::NewLine, $utf8NoBom)

Write-Host "Wrote Kubernetes explanation: $resolvedOutputPath"
