param(
    [string]$Root = "C:\K3s"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$resolvedRoot = (Resolve-Path $Root).Path.TrimEnd('\')
if (-not $resolvedRoot.Equals("C:\K3s", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Root must remain C:\K3s for this migration boundary check: $resolvedRoot"
}

$composeRoot = "C:\compose"
$forbiddenComposeBackupRoot = $composeRoot + "\backups"
$disallowedYamlExtension = ".ya" + "ml"

$allowedComposeReferenceFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
@(
    "README.md",
    "cutover-checklist.md",
    "inventory.md",
    "pending-inputs.ko.md",
    "secrets\docky-k3s-extra.env.example",
    "templates\cutover-runbook.ko.md",
    "templates\rollback-runbook.ko.md",
    "templates\cutover-input-report.ko.md",
    "templates\explan.ko.md",
    "scripts\Invoke-K3sComposeBackup.ps1",
    "scripts\Invoke-K3sImagePipeline.ps1",
    "scripts\New-K3sCutoverRunbook.ps1",
    "scripts\New-K3sRollbackRunbook.ps1",
    "scripts\New-DockySecretFromEnv.ps1",
    "scripts\Test-K3sComposeBoundary.ps1",
    "scripts\Test-K3sComposeParity.ps1",
    "scripts\Test-K3sBackupPreflight.ps1",
    "scripts\Test-K3sFrontendStaticSource.ps1",
    "scripts\Test-K3sCutoverInputs.ps1",
    "scripts\Test-K3sManifests.ps1",
    "scripts\Test-K3sRenderedSnapshots.ps1",
    "scripts\Test-K3sReleaseImages.ps1",
    "scripts\Test-K3sRunbooks.ps1",
    "scripts\Test-K3sSecretSources.ps1",
    "scripts\Test-K3sStoragePlan.ps1"
) | ForEach-Object { [void]$allowedComposeReferenceFiles.Add($_) }

$requiredGuards = @{
    "scripts\Build-BackendImage.ps1" = @("Root must remain C:\K3s for generated Docker build context")
    "scripts\Build-FrontendImage.ps1" = @("Root must remain C:\K3s for generated Docker build context")
    "scripts\Collect-K3sDiagnostics.ps1" = @("OutputRoot must stay under C:\K3s\runtime\diagnostics")
    "scripts\Export-K3sRenderedManifests.ps1" = @("OutputRoot must stay under C:\K3s\runtime\rendered")
    "scripts\Import-K3sKubeconfig.ps1" = @("OutputPath must stay under C:\K3s\runtime")
    "scripts\Invoke-K3sComposeBackup.ps1" = @("BackupRoot must stay under C:\K3s\backups", "ComposeRoot must remain C:\compose")
    "scripts\Invoke-K3sOracleRestore.ps1" = @("OutputDir must stay under C:\K3s\backups", "Oracle restore source must be under C:\K3s\backups")
    "scripts\Invoke-K3sOracleSqlfileRehearsal.ps1" = @("OutputDir must stay under C:\K3s\backups", "Oracle SQLFILE rehearsal source must be under C:\K3s\backups")
    "scripts\New-DockySecretFromEnv.ps1" = @("OutputPath must stay under C:\K3s\runtime", "ExtraEnvPath must not be stored under C:\compose")
    "scripts\New-GhcrImagePullSecret.ps1" = @("OutputPath must stay under C:\K3s\runtime")
    "scripts\New-K3sCutoverRunbook.ps1" = @("OutputRoot must stay under C:\K3s\runtime")
    "scripts\Set-K3sImageTags.ps1" = @("KustomizationPath must stay under C:\K3s")
    "scripts\Test-K3sCutoverInputs.ps1" = @("ReportRoot must stay under C:\K3s\runtime")
}

$findings = New-Object System.Collections.Generic.List[string]
$files = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File |
    Where-Object {
        $_.FullName -notmatch '\\runtime\\' -and
        $_.FullName -notmatch '\\backups\\' -and
        $_.FullName -notmatch '\\build\\[^\\]+\\context\\'
    }

foreach ($file in $files) {
    $relative = $file.FullName.Substring($resolvedRoot.Length + 1)
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

    if ($file.Extension -eq $disallowedYamlExtension) {
        $findings.Add("Use .yml extension only: $relative")
    }

    if ($text.Contains($forbiddenComposeBackupRoot)) {
        $findings.Add("Do not write or document backup output under ${forbiddenComposeBackupRoot}: $relative")
    }

    if ($text.Contains($composeRoot) -and -not $allowedComposeReferenceFiles.Contains($relative)) {
        $findings.Add("Unexpected C:\compose reference in $relative")
    }

    $lines = $text -split "\r?\n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $hasCompose = $line -match 'C:\\compose|C:/compose'
        $hasWriteCommand = $line -match '\b(Set-Content|WriteAllText|New-Item|Copy-Item|Move-Item|Remove-Item|Out-File)\b'
        if ($hasCompose -and $hasWriteCommand) {
            $findings.Add("Potential direct write to C:\compose at ${relative}:$($i + 1)")
        }
        if ($line -match '\[(string|System\.String)\]\$(OutputPath|OutputRoot|OutputDir|BackupRoot|Root)\s*=\s*"C:\\compose') {
            $findings.Add("Writable parameter defaults to C:\compose at ${relative}:$($i + 1)")
        }
    }
}

foreach ($entry in $requiredGuards.GetEnumerator()) {
    $path = Join-Path $resolvedRoot $entry.Key
    if (-not (Test-Path $path)) {
        $findings.Add("Guarded script missing: $($entry.Key)")
        continue
    }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    foreach ($guard in $entry.Value) {
        if (-not $text.Contains($guard)) {
            $findings.Add("Missing boundary guard '$guard' in $($entry.Key)")
        }
    }
}

if ($findings.Count -gt 0) {
    throw "K3s/Compose boundary checks failed:`n$($findings -join [Environment]::NewLine)"
}

Write-Host "K3s/Compose boundary checks passed."
