param(
    [string]$Root = "C:\K3s",
    [string]$Kubeconfig = "C:\K3s\runtime\kubeconfig.yml",
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    [string]$BaseUrl = "https://docky.co.kr",
    [string]$DockySecretPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$GhcrSecretPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [int]$RuntimeTimeoutSeconds = 600,
    [int]$SmokeTimeoutSeconds = 15,
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$AllowEmptyRedis
)

$ErrorActionPreference = "Stop"

function Invoke-Gate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Gate script not found for ${Name}: $ScriptPath"
    }

    Write-Host "Completion gate: $Name"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Completion gate failed: $Name"
    }
}

function Get-LatestRenderedSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RenderRoot,
        [Parameter(Mandatory = $true)][string]$Environment
    )

    if (-not (Test-Path $RenderRoot)) {
        throw "Rendered manifest snapshot root not found: $RenderRoot"
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

    throw "No rendered manifest snapshot found for environment ${Environment} under $RenderRoot"
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}
if (-not (Test-Path $Kubeconfig)) {
    throw "Kubeconfig is required for completion evidence: $Kubeconfig"
}
if (-not (Test-Path $BackupPath)) {
    throw "BackupPath is required for completion evidence: $BackupPath"
}
if (-not (Test-Path $DockySecretPath)) {
    throw "Docky runtime secret manifest is required for completion evidence: $DockySecretPath"
}
if (-not (Test-Path $GhcrSecretPath)) {
    throw "GHCR pull secret manifest is required for completion evidence: $GhcrSecretPath"
}

$resolvedBackupRoot = (Resolve-Path (Join-Path $Root "backups")).Path
$resolvedBackupPath = (Resolve-Path $BackupPath).Path
if (-not $resolvedBackupPath.StartsWith($resolvedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupPath must stay under ${resolvedBackupRoot}: $resolvedBackupPath"
}

$scriptsRoot = Join-Path $Root "scripts"

Invoke-Gate -Name "migration workspace boundary" `
    -ScriptPath (Join-Path $scriptsRoot "Test-K3sComposeBoundary.ps1")

Invoke-Gate -Name "production cutover and rollback runbooks" `
    -ScriptPath (Join-Path $scriptsRoot "Test-K3sRunbooks.ps1") `
    -Arguments @("-Environment", "production", "-RequireGeneratedRunbook", "-RequireRollbackRunbook")

Invoke-Gate -Name "production rendered snapshot evidence" `
    -ScriptPath (Join-Path $scriptsRoot "Test-K3sRenderedSnapshots.ps1") `
    -Arguments @("-Environment", "production", "-RequireSnapshot", "-FailOnPlaceholderImages")

$cutoverArgs = @(
    "-Environment", "production",
    "-Root", $Root,
    "-Kubeconfig", $Kubeconfig,
    "-BackupPath", $BackupPath,
    "-DockySecretPath", $DockySecretPath,
    "-GhcrSecretPath", $GhcrSecretPath
)
if ($IncludeCloudflared) {
    $cutoverArgs += "-IncludeCloudflared"
}
if ($BootstrapMinio) {
    $cutoverArgs += "-BootstrapMinio"
}
Invoke-Gate -Name "production cutover preflight" `
    -ScriptPath (Join-Path $scriptsRoot "Test-K3sCutoverGate.ps1") `
    -Arguments $cutoverArgs

$dryRunArgs = @(
    "-Environment", "production",
    "-Root", $Root,
    "-Kubeconfig", $Kubeconfig,
    "-DockySecretPath", $DockySecretPath,
    "-GhcrSecretPath", $GhcrSecretPath
)
if ($IncludeCloudflared) {
    $dryRunArgs += "-IncludeCloudflared"
}
if ($BootstrapMinio) {
    $dryRunArgs += "-BootstrapMinio"
}
Invoke-Gate -Name "production server dry-run" `
    -ScriptPath (Join-Path $scriptsRoot "Test-K3sServerDryRun.ps1") `
    -Arguments $dryRunArgs

$restoreArgs = @(
    "-Kubeconfig", $Kubeconfig,
    "-BackupPath", $BackupPath
)
if ($AllowEmptyRedis) {
    $restoreArgs += "-AllowEmptyRedis"
}
Invoke-Gate -Name "restored data validation" `
    -ScriptPath (Join-Path $scriptsRoot "Test-K3sRestoredData.ps1") `
    -Arguments $restoreArgs

$diagnosticsRoot = Join-Path $Root "runtime\diagnostics"
$postApplyStart = Get-Date
$postApplyArgs = @(
    "-Kubeconfig", $Kubeconfig,
    "-BaseUrl", $BaseUrl,
    "-RuntimeTimeoutSeconds", [string]$RuntimeTimeoutSeconds,
    "-SmokeTimeoutSeconds", [string]$SmokeTimeoutSeconds,
    "-IncludeExternalServices",
    "-IncludeWebSocket"
)
if ($IncludeCloudflared) {
    $postApplyArgs += "-IncludeCloudflared"
}
Invoke-Gate -Name "production post-apply validation" `
    -ScriptPath (Join-Path $scriptsRoot "Invoke-K3sPostApplyValidation.ps1") `
    -Arguments $postApplyArgs

if (-not (Test-Path $diagnosticsRoot)) {
    throw "Diagnostics root was not created by post-apply validation: $diagnosticsRoot"
}
$latestDiagnostics = Get-ChildItem -LiteralPath $diagnosticsRoot -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $latestDiagnostics) {
    throw "No diagnostics snapshot found under $diagnosticsRoot"
}
if ($latestDiagnostics.LastWriteTime -lt $postApplyStart.AddSeconds(-5)) {
    throw "Latest diagnostics snapshot is older than this completion run: $($latestDiagnostics.FullName)"
}

$renderRoot = Join-Path $Root "runtime\rendered"
$latestRender = Get-LatestRenderedSnapshot -RenderRoot $renderRoot -Environment "production"

Write-Host "K3s completion evidence passed."
Write-Host "Latest rendered snapshot: $($latestRender.FullName)"
Write-Host "Latest diagnostics snapshot: $($latestDiagnostics.FullName)"
Write-Host "It is now safe to create C:\K3s\explan.md."
