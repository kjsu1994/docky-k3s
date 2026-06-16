param(
    [string]$Root = "C:\K3s",
    [string]$Kubeconfig = "C:\K3s\runtime\kubeconfig.yml",
    [string]$BackupPath
)

$ErrorActionPreference = "Stop"

function Add-Status {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$Detail = ""
    )

    $Target.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Invoke-CheckCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [System.Collections.Generic.List[object]]$Target
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousNativePreference = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        $previousNativePreference = $Global:PSNativeCommandUseErrorActionPreference
        $Global:PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $ErrorActionPreference = "Continue"
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $output = $_
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -ne $previousNativePreference) {
            $Global:PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }
    $text = (($output | Out-String).Trim())
    if ($exitCode -eq 0) {
        Add-Status -Target $Target -Name $Name -Status "PASS" -Detail $text
    } else {
        Add-Status -Target $Target -Name $Name -Status "FAIL" -Detail $text
    }
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$results = New-Object System.Collections.Generic.List[object]

Invoke-CheckCommand -Name "local-readiness" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sLocalReadiness.ps1")
}

Invoke-CheckCommand -Name "compose-boundary-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sComposeBoundary.ps1")
}

Invoke-CheckCommand -Name "docker-desktop-manifest-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1") `
        -Environment docker-desktop `
        -FailOnPlaceholderImages
}

Invoke-CheckCommand -Name "staging-manifest-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1") `
        -Environment staging `
        -FailOnPlaceholderImages
}

Invoke-CheckCommand -Name "production-manifest-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sManifests.ps1") `
        -Environment production `
        -FailOnPlaceholderImages
}

Invoke-CheckCommand -Name "image-policy-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sImagePolicy.ps1") `
        -IncludeCloudflared `
        -IncludeJobs `
        -IncludeBuildFiles `
        -IncludeScripts `
        -FailOnMutableTags
}

Invoke-CheckCommand -Name "runbook-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sRunbooks.ps1") `
        -RequireGeneratedRunbook `
        -RequireRollbackRunbook
}

Invoke-CheckCommand -Name "secret-source-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sSecretSources.ps1") `
        -RequireExtraEnv `
        -RequireAllKeys
}

Invoke-CheckCommand -Name "backup-preflight-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sBackupPreflight.ps1") `
        -RequireDocker `
        -RequireBackupRoot
}

Invoke-CheckCommand -Name "cutover-input-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sCutoverInputs.ps1") `
        -Strict
}

Invoke-CheckCommand -Name "rendered-snapshot-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sRenderedSnapshots.ps1")
}

Invoke-CheckCommand -Name "docker-desktop-release-image-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sReleaseImages.ps1") `
        -Environment docker-desktop
}

Invoke-CheckCommand -Name "staging-release-image-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sReleaseImages.ps1") `
        -Environment staging
}

Invoke-CheckCommand -Name "production-release-image-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sReleaseImages.ps1") `
        -Environment production
}

Invoke-CheckCommand -Name "docker-desktop-external-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sExternalDependencies.ps1") `
        -Environment docker-desktop `
        -FailOnUnresolved
}

Invoke-CheckCommand -Name "docker-desktop-local-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sDockerDesktopReadiness.ps1") `
        -SkipImageRuntime
}

Invoke-CheckCommand -Name "production-external-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sExternalDependencies.ps1") `
        -Environment production `
        -FailOnUnresolved
}

Invoke-CheckCommand -Name "compose-parity" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sComposeParity.ps1") -FailOnMismatch
}

Invoke-CheckCommand -Name "runtime-secret-gate" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sSecretManifests.ps1")
}

Invoke-CheckCommand -Name "storage-plan" -Target $results -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sStoragePlan.ps1") -FailOnInsufficient
}

if (Test-Path $Kubeconfig) {
    try {
        $context = & kubectl --kubeconfig $Kubeconfig config current-context 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($context)) {
            Add-Status -Target $results -Name "runtime-kubeconfig" -Status "PASS" -Detail "current-context=$context"
            Invoke-CheckCommand -Name "cluster-prereqs" -Target $results -Command {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sClusterPrereqs.ps1") `
                    -Kubeconfig $Kubeconfig
            }
        } else {
            Add-Status -Target $results -Name "runtime-kubeconfig" -Status "FAIL" -Detail "No current-context in $Kubeconfig"
        }
    } catch {
        Add-Status -Target $results -Name "runtime-kubeconfig" -Status "FAIL" -Detail $_.Exception.Message
    }
} else {
    Add-Status -Target $results -Name "runtime-kubeconfig" -Status "WARN" -Detail "Not found: $Kubeconfig"
    Add-Status -Target $results -Name "cluster-prereqs" -Status "WARN" -Detail "Skipped because kubeconfig is missing."
}

$renderRoot = Join-Path $Root "runtime\rendered"
if (Test-Path $renderRoot) {
    $latestRender = Get-ChildItem -LiteralPath $renderRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestRender) {
        Add-Status -Target $results -Name "render-snapshot" -Status "PASS" -Detail $latestRender.FullName
    } else {
        Add-Status -Target $results -Name "render-snapshot" -Status "WARN" -Detail "No rendered snapshot directory found under $renderRoot."
    }
} else {
    Add-Status -Target $results -Name "render-snapshot" -Status "WARN" -Detail "Not found: $renderRoot"
}

foreach ($environmentName in @("production", "staging", "docker-desktop")) {
    if (Test-Path $renderRoot) {
        $environmentRender = Get-ChildItem -LiteralPath $renderRoot -Directory |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $metadataPath = Join-Path $_.FullName "metadata.json"
                if (Test-Path $metadataPath) {
                    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
                    if ($metadata.environment -eq $environmentName) {
                        $_
                    }
                }
            } |
            Select-Object -First 1
        if ($environmentRender) {
            Add-Status -Target $results -Name "render-snapshot-$environmentName" -Status "PASS" -Detail $environmentRender.FullName
        } else {
            Add-Status -Target $results -Name "render-snapshot-$environmentName" -Status "WARN" -Detail "No rendered snapshot found for $environmentName under $renderRoot."
        }
    }
}

$diagnosticsRoot = Join-Path $Root "runtime\diagnostics"
if (Test-Path $diagnosticsRoot) {
    $latestDiagnostics = Get-ChildItem -LiteralPath $diagnosticsRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestDiagnostics) {
        Add-Status -Target $results -Name "diagnostics-snapshot" -Status "PASS" -Detail $latestDiagnostics.FullName
    } else {
        Add-Status -Target $results -Name "diagnostics-snapshot" -Status "WARN" -Detail "No diagnostics snapshot directory found under $diagnosticsRoot."
    }
} else {
    Add-Status -Target $results -Name "diagnostics-snapshot" -Status "WARN" -Detail "Not found: $diagnosticsRoot"
}

$reportRoot = Join-Path $Root "runtime\reports"
if (Test-Path $reportRoot) {
    $latestInputReport = Get-ChildItem -LiteralPath $reportRoot -File -Filter "cutover-inputs-*.md" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestInputReport) {
        Add-Status -Target $results -Name "cutover-input-report" -Status "PASS" -Detail $latestInputReport.FullName
    } else {
        Add-Status -Target $results -Name "cutover-input-report" -Status "WARN" -Detail "No cutover input report found under $reportRoot."
    }
} else {
    Add-Status -Target $results -Name "cutover-input-report" -Status "WARN" -Detail "Not found: $reportRoot"
}

$explanationPath = Join-Path $Root "explan.md"
if (Test-Path $explanationPath) {
    Add-Status -Target $results -Name "explanation-doc" -Status "PASS" -Detail $explanationPath
} else {
    Add-Status -Target $results -Name "explanation-doc" -Status "WARN" -Detail "Not created yet. Generate with New-K3sExplanation.ps1 after Test-K3sCompletionGate.ps1 passes."
}

$runbookRoot = Join-Path $Root "runtime\runbooks"
if (Test-Path $runbookRoot) {
    $latestRunbook = Get-ChildItem -LiteralPath $runbookRoot -File -Filter "cutover-*.md" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestRunbook) {
        Add-Status -Target $results -Name "cutover-runbook" -Status "PASS" -Detail $latestRunbook.FullName
    } else {
        Add-Status -Target $results -Name "cutover-runbook" -Status "WARN" -Detail "No cutover runbook found under $runbookRoot."
    }
} else {
    Add-Status -Target $results -Name "cutover-runbook" -Status "WARN" -Detail "Not found: $runbookRoot"
}

foreach ($environmentName in @("production", "staging", "docker-desktop")) {
    if (Test-Path $runbookRoot) {
        $latestEnvironmentRunbook = Get-ChildItem -LiteralPath $runbookRoot -File -Filter "cutover-$environmentName-*.md" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latestEnvironmentRunbook) {
            Add-Status -Target $results -Name "cutover-runbook-$environmentName" -Status "PASS" -Detail $latestEnvironmentRunbook.FullName
        } else {
            Add-Status -Target $results -Name "cutover-runbook-$environmentName" -Status "WARN" -Detail "No $environmentName runbook found under $runbookRoot."
        }
    }
}

foreach ($environmentName in @("production", "staging", "docker-desktop")) {
    if (Test-Path $runbookRoot) {
        $latestRollbackRunbook = Get-ChildItem -LiteralPath $runbookRoot -File -Filter "rollback-$environmentName-*.md" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latestRollbackRunbook) {
            Add-Status -Target $results -Name "rollback-runbook-$environmentName" -Status "PASS" -Detail $latestRollbackRunbook.FullName
        } else {
            Add-Status -Target $results -Name "rollback-runbook-$environmentName" -Status "WARN" -Detail "No $environmentName rollback runbook found under $runbookRoot."
        }
    }
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $backupRoot = Join-Path $Root "backups"
    $latestBackup = $null
    if (Test-Path $backupRoot) {
        $latestBackup = Get-ChildItem -LiteralPath $backupRoot -Directory |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    if ($latestBackup) {
        $BackupPath = $latestBackup.FullName
    }
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    Add-Status -Target $results -Name "backup-set" -Status "WARN" -Detail "No backup session found under C:\K3s\backups."
} else {
    Invoke-CheckCommand -Name "backup-set" -Target $results -Command {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\Test-K3sBackupSet.ps1") `
            -BackupPath $BackupPath `
            -RequireOracle `
            -RequireRedis `
            -RequireMinio `
            -RequireMinioContent
    }
}

$results | Format-Table -AutoSize

$failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = @($results | Where-Object { $_.Status -eq "WARN" }).Count
Write-Host "Summary: PASS=$(@($results | Where-Object { $_.Status -eq "PASS" }).Count) WARN=$warnCount FAIL=$failCount"

if ($failCount -gt 0) {
    exit 1
}
