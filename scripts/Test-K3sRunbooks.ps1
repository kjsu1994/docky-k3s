param(
    [string]$Root = "C:\K3s",
    [ValidateSet("all", "production", "staging", "docker-desktop")]
    [string]$Environment = "all",
    [switch]$RequireGeneratedRunbook,
    [switch]$RequireRollbackRunbook,
    [switch]$AllGeneratedRunbooks
)

$ErrorActionPreference = "Stop"

function Read-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Assert-NoEncodingDamage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $markers = @(
        [char]0xFFFD,
        [char]0x00C2,
        [char]0x00C3,
        [char]0x00EC,
        [char]0x00EA,
        [char]0x00EB
    )
    foreach ($marker in $markers) {
        if ($Text.Contains([string]$marker)) {
            throw "Possible UTF-8/mojibake damage in ${Path}."
        }
    }
}

function Assert-RunbookText {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$Runbook,
        [Parameter(Mandatory = $true)][string]$Text
    )

    if ($Runbook.Name -notmatch '^cutover-(production|staging|docker-desktop)-\d{8}-\d{6}\.md$') {
        throw "Unexpected cutover runbook filename: $($Runbook.FullName)"
    }

    $environment = $Matches[1]

    if ($Text -match '__[A-Z0-9_]+__') {
        throw "Unresolved template placeholder remains in $($Runbook.FullName): $($Matches[0])"
    }
    $disallowedYamlExtension = ".ya" + "ml"
    if ($Text -match ([regex]::Escape($disallowedYamlExtension) + '\b')) {
        throw "Runbook must use .yml extension only: $($Runbook.FullName)"
    }

    if ($environment -eq "docker-desktop") {
        foreach ($blocked in @("-RequireRegistryAvailability", "New-GhcrImagePullSecret.ps1", "Set-K3sIotExternalName.ps1", "Set-K3sOllamaExternalName.ps1")) {
            if ($Text.Contains($blocked)) {
                throw "Docker Desktop runbook contains production-only command or flag: $blocked"
            }
        }
        foreach ($blockedLine in @("  -Push", "  -UpdateManifests")) {
            if ($Text -match "(?m)^\s*$([regex]::Escape($blockedLine.Trim()))\s*$") {
                throw "Docker Desktop runbook contains production image pipeline flag: $blockedLine"
            }
        }
        if (-not $Text.Contains("C:\K3s\overlays\docker-desktop\kustomization.yml")) {
            throw "Docker Desktop runbook must update only the docker-desktop overlay kustomization."
        }
        if (-not $Text.Contains("-SkipGhcrSecret")) {
            throw "Docker Desktop runbook must skip GHCR pull secret validation."
        }
    } else {
        foreach ($required in @("-RequireRegistryAvailability", "New-GhcrImagePullSecret.ps1", "  -Push", "  -UpdateManifests")) {
            if (-not $Text.Contains($required)) {
                throw "$environment runbook is missing required production/staging image or secret step: $required"
            }
        }
        if ($Text -match '(?m)^Release tag:\s*(replace-me|latest|stable|local[_.-]|dev[_.-]|test[_.-]|tmp[_.-]|scratch[_.-]|.*(compose-current|validator|verify|wip).*)\s*$') {
            throw "$environment runbook uses a non-release tag."
        }
        if ($environment -eq "production" -and -not $Text.Contains("New-K3sExplanation.ps1")) {
            throw "Production runbook must include completion-gated explan.md generation."
        }
        if ($environment -eq "staging" -and $Text.Contains("New-K3sExplanation.ps1")) {
            throw "Staging runbook must not generate explan.md."
        }
    }
}

function Assert-RollbackRunbookText {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$Runbook,
        [Parameter(Mandatory = $true)][string]$Text
    )

    if ($Runbook.Name -notmatch '^rollback-(production|staging|docker-desktop)-\d{8}-\d{6}\.md$') {
        throw "Unexpected rollback runbook filename: $($Runbook.FullName)"
    }

    if ($Text -match '__[A-Z0-9_]+__') {
        throw "Unresolved template placeholder remains in $($Runbook.FullName): $($Matches[0])"
    }
    $disallowedYamlExtension = ".ya" + "ml"
    if ($Text -match ([regex]::Escape($disallowedYamlExtension) + '\b')) {
        throw "Rollback runbook must use .yml extension only: $($Runbook.FullName)"
    }
    $composeRootText = "C:\com" + "pose"
    foreach ($required in @("Collect-K3sDiagnostics.ps1", "Test-K3sHttpSmoke.ps1", "kubectl --kubeconfig", "kubectl delete pvc", "kubectl delete namespace docky", $composeRootText)) {
        if (-not $Text.Contains($required)) {
            throw "Rollback runbook is missing required rollback safety text: $required"
        }
    }
    foreach ($blocked in @("kubectl delete pvc -n", "kubectl delete namespace docky --force", ("Remove-Item -LiteralPath " + $composeRootText))) {
        if ($Text.Contains($blocked)) {
            throw "Rollback runbook contains destructive rollback command: $blocked"
        }
    }
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$templatePaths = @(
    (Join-Path $Root "templates\cutover-runbook.ko.md"),
    (Join-Path $Root "templates\rollback-runbook.ko.md"),
    (Join-Path $Root "templates\explan.ko.md")
)

foreach ($path in $templatePaths) {
    if (-not (Test-Path $path)) {
        throw "Required template missing: $path"
    }
    $text = Read-Utf8Text -Path $path
    Assert-NoEncodingDamage -Path $path -Text $text
}

$runbookRoot = Join-Path $Root "runtime\runbooks"
$environmentPattern = if ($Environment -eq "all") {
    "production|staging|docker-desktop"
} else {
    [regex]::Escape($Environment)
}

$runbooks = @()
if (Test-Path $runbookRoot) {
    $allRunbooks = @(Get-ChildItem -LiteralPath $runbookRoot -File -Filter "cutover-*.md")
    if ($AllGeneratedRunbooks) {
        $runbooks = @($allRunbooks | Where-Object { $_.Name -match "^cutover-($environmentPattern)-\d{8}-\d{6}\.md$" })
    } else {
        $runbooks = @(
            $allRunbooks |
                Where-Object { $_.Name -match "^cutover-($environmentPattern)-\d{8}-\d{6}\.md$" } |
                Group-Object { [regex]::Match($_.Name, '^cutover-(production|staging|docker-desktop)-').Groups[1].Value } |
                ForEach-Object {
                    $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                }
        )
    }
}

if ($RequireGeneratedRunbook -and $runbooks.Count -eq 0) {
    throw "No generated cutover runbook found for $Environment under $runbookRoot."
}
if ($RequireGeneratedRunbook -and $Environment -eq "all") {
    $presentCutoverEnvironments = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($runbook in $runbooks) {
        if ($runbook.Name -match '^cutover-(production|staging|docker-desktop)-') {
            [void]$presentCutoverEnvironments.Add($Matches[1])
        }
    }
    $missingCutoverEnvironments = @("production", "staging", "docker-desktop") | Where-Object { -not $presentCutoverEnvironments.Contains($_) }
    if ($missingCutoverEnvironments) {
        throw "Missing generated cutover runbook for environment(s): $($missingCutoverEnvironments -join ', ')"
    }
}

foreach ($runbook in $runbooks) {
    $text = Read-Utf8Text -Path $runbook.FullName
    Assert-NoEncodingDamage -Path $runbook.FullName -Text $text
    Assert-RunbookText -Runbook $runbook -Text $text
}

$rollbackRunbooks = @()
if (Test-Path $runbookRoot) {
    $allRollbackRunbooks = @(Get-ChildItem -LiteralPath $runbookRoot -File -Filter "rollback-*.md")
    if ($AllGeneratedRunbooks) {
        $rollbackRunbooks = @($allRollbackRunbooks | Where-Object { $_.Name -match "^rollback-($environmentPattern)-\d{8}-\d{6}\.md$" })
    } else {
        $rollbackRunbooks = @(
            $allRollbackRunbooks |
                Where-Object { $_.Name -match "^rollback-($environmentPattern)-\d{8}-\d{6}\.md$" } |
                Group-Object { [regex]::Match($_.Name, '^rollback-(production|staging|docker-desktop)-').Groups[1].Value } |
                ForEach-Object {
                    $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                }
        )
    }
}

if ($RequireRollbackRunbook -and $rollbackRunbooks.Count -eq 0) {
    throw "No generated rollback runbook found for $Environment under $runbookRoot."
}
if ($RequireRollbackRunbook -and $Environment -eq "all") {
    $presentRollbackEnvironments = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($runbook in $rollbackRunbooks) {
        if ($runbook.Name -match '^rollback-(production|staging|docker-desktop)-') {
            [void]$presentRollbackEnvironments.Add($Matches[1])
        }
    }
    $missingRollbackEnvironments = @("production", "staging", "docker-desktop") | Where-Object { -not $presentRollbackEnvironments.Contains($_) }
    if ($missingRollbackEnvironments) {
        throw "Missing generated rollback runbook for environment(s): $($missingRollbackEnvironments -join ', ')"
    }
}

foreach ($runbook in $rollbackRunbooks) {
    $text = Read-Utf8Text -Path $runbook.FullName
    Assert-NoEncodingDamage -Path $runbook.FullName -Text $text
    Assert-RollbackRunbookText -Runbook $runbook -Text $text
}

Write-Host "K3s runbook checks passed."
foreach ($runbook in ($runbooks | Sort-Object Name)) {
    Write-Host "Runbook: $($runbook.FullName)"
}
foreach ($runbook in ($rollbackRunbooks | Sort-Object Name)) {
    Write-Host "Rollback: $($runbook.FullName)"
}
