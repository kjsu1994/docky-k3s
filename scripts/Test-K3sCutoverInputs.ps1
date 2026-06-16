param(
    [string]$Root = "C:\K3s",
    [ValidateSet("all", "production", "staging", "docker-desktop")]
    [string]$Environment = "all",
    [string]$Kubeconfig = "C:\K3s\runtime\kubeconfig.yml",
    [string]$BackupPath,
    [switch]$Strict,
    [switch]$RequireRegistryImageAvailability,
    [switch]$WriteReport,
    [string]$ReportRoot = "C:\K3s\runtime\reports"
)

$ErrorActionPreference = "Stop"

function Add-InputResult {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Detail = ""
    )

    $Target.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Invoke-InputCheck {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [switch]$Required
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
        Add-InputResult -Target $Target -Name $Name -Status "PASS" -Detail $text
    } elseif ($Strict -or $Required) {
        Add-InputResult -Target $Target -Name $Name -Status "FAIL" -Detail $text
    } else {
        Add-InputResult -Target $Target -Name $Name -Status "WARN" -Detail $text
    }
}

function ConvertTo-MarkdownCell {
    param(
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    $text = ([string]$Value).Trim()
    if ($text.Length -gt 1600) {
        $text = $text.Substring(0, 1600) + "..."
    }

    return $text.
        Replace("|", "\|").
        Replace("`r`n", "<br>").
        Replace("`n", "<br>").
        Replace("`r", "<br>")
}

function Write-InputReport {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ReportRoot,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory = $true)][string]$Environment,
        [Parameter(Mandatory = $true)][string]$Kubeconfig,
        [string]$BackupPath,
        [Parameter(Mandatory = $true)][int]$PassCount,
        [Parameter(Mandatory = $true)][int]$WarnCount,
        [Parameter(Mandatory = $true)][int]$FailCount,
        [switch]$Strict,
        [switch]$RequireRegistryImageAvailability
    )

    $runtimeRoot = Join-Path $Root "runtime"
    $resolvedRuntimeRoot = [System.IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\')
    $resolvedReportRoot = [System.IO.Path]::GetFullPath($ReportRoot).TrimEnd('\')
    if (-not ($resolvedReportRoot.Equals($resolvedRuntimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $resolvedReportRoot.StartsWith($resolvedRuntimeRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "ReportRoot must stay under C:\K3s\runtime: $resolvedReportRoot"
    }

    $templatePath = Join-Path $Root "templates\cutover-input-report.ko.md"
    if (-not (Test-Path $templatePath)) {
        throw "Cutover input report template not found: $templatePath"
    }

    if (-not (Test-Path $resolvedReportRoot)) {
        New-Item -ItemType Directory -Path $resolvedReportRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $markdownPath = Join-Path $resolvedReportRoot "cutover-inputs-$timestamp.md"
    $jsonPath = Join-Path $resolvedReportRoot "cutover-inputs-$timestamp.json"
    $generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    $backupPathForReport = if ([string]::IsNullOrWhiteSpace($BackupPath)) { "(not supplied)" } else { $BackupPath }

    $payload = [pscustomobject]@{
        generatedAt = (Get-Date).ToString("o")
        root = $Root
        environment = $Environment
        kubeconfig = $Kubeconfig
        backupPath = $backupPathForReport
        strict = [bool]$Strict
        requireRegistryImageAvailability = [bool]$RequireRegistryImageAvailability
        summary = [pscustomobject]@{
            pass = $PassCount
            warn = $WarnCount
            fail = $FailCount
        }
        results = @($Results | Select-Object Name, Status, Detail)
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, (($payload | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $utf8NoBom)

    $rows = @($Results | ForEach-Object {
        "| $(ConvertTo-MarkdownCell $_.Name) | $(ConvertTo-MarkdownCell $_.Status) | $(ConvertTo-MarkdownCell $_.Detail) |"
    }) -join [Environment]::NewLine

    $template = Get-Content -Raw -Encoding UTF8 -LiteralPath $templatePath
    $content = $template.
        Replace("__GENERATED_AT__", $generatedAt).
        Replace("__ROOT__", $Root).
        Replace("__ENVIRONMENT__", $Environment).
        Replace("__KUBECONFIG__", $Kubeconfig).
        Replace("__BACKUP_PATH__", $backupPathForReport).
        Replace("__STRICT_MODE__", [string][bool]$Strict).
        Replace("__REQUIRE_REGISTRY__", [string][bool]$RequireRegistryImageAvailability).
        Replace("__PASS_COUNT__", [string]$PassCount).
        Replace("__WARN_COUNT__", [string]$WarnCount).
        Replace("__FAIL_COUNT__", [string]$FailCount).
        Replace("__JSON_PATH__", $jsonPath).
        Replace("__RESULT_ROWS__", $rows)

    [System.IO.File]::WriteAllText($markdownPath, $content + [Environment]::NewLine, $utf8NoBom)

    Write-Host "Cutover input report: $markdownPath"
    Write-Host "Cutover input JSON: $jsonPath"
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

$scriptsRoot = Join-Path $Root "scripts"
$results = New-Object System.Collections.Generic.List[object]
$targetEnvironments = if ($Environment -eq "all") {
    @("production", "staging", "docker-desktop")
} else {
    @($Environment)
}

Invoke-InputCheck -Target $results -Name "backup-preflight" -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sBackupPreflight.ps1") -RequireBackupRoot
}

Invoke-InputCheck -Target $results -Name "secret-source" -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sSecretSources.ps1") -RequireExtraEnv -RequireAllKeys
}

Invoke-InputCheck -Target $results -Name "runtime-secrets" -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sSecretManifests.ps1")
}

Invoke-InputCheck -Target $results -Name "kubeconfig" -Command {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $context = & kubectl --kubeconfig $Kubeconfig config current-context
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($context)) {
        throw "Kubeconfig has no current-context: $Kubeconfig"
    }
    Write-Host "current-context=$context"
}

$backupSetArgs = @(
    "-RequireOracle",
    "-RequireRedis",
    "-RequireMinio",
    "-RequireMinioContent"
)
if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    $backupSetArgs += @("-BackupPath", $BackupPath)
}
Invoke-InputCheck -Target $results -Name "backup-set" -Command {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sBackupSet.ps1") @backupSetArgs
}

foreach ($environmentName in $targetEnvironments) {
    Invoke-InputCheck -Target $results -Name "runbooks-$environmentName" -Command {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sRunbooks.ps1") `
            -Environment $environmentName `
            -RequireGeneratedRunbook `
            -RequireRollbackRunbook
    }

    Invoke-InputCheck -Target $results -Name "release-images-$environmentName" -Command {
        $releaseArgs = @("-Environment", $environmentName)
        if ($RequireRegistryImageAvailability) {
            $releaseArgs += "-RequireRegistryAvailability"
        }
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sReleaseImages.ps1") @releaseArgs
    }

    Invoke-InputCheck -Target $results -Name "external-dependencies-$environmentName" -Command {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sExternalDependencies.ps1") `
            -Environment $environmentName `
            -FailOnUnresolved
    }

    Invoke-InputCheck -Target $results -Name "rendered-snapshot-$environmentName" -Command {
        $snapshotArgs = @(
            "-Environment", $environmentName,
            "-RequireSnapshot"
        )
        if ($environmentName -ne "docker-desktop") {
            $snapshotArgs += "-FailOnPlaceholderImages"
        }
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Test-K3sRenderedSnapshots.ps1") @snapshotArgs
    }
}

$results | Format-Table -AutoSize

$failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = @($results | Where-Object { $_.Status -eq "WARN" }).Count
$passCount = @($results | Where-Object { $_.Status -eq "PASS" }).Count

if ($WriteReport) {
    Write-InputReport `
        -Root $Root `
        -ReportRoot $ReportRoot `
        -Results $results `
        -Environment $Environment `
        -Kubeconfig $Kubeconfig `
        -BackupPath $BackupPath `
        -PassCount $passCount `
        -WarnCount $warnCount `
        -FailCount $failCount `
        -Strict:$Strict `
        -RequireRegistryImageAvailability:$RequireRegistryImageAvailability
}

Write-Host "Cutover input summary: PASS=$passCount WARN=$warnCount FAIL=$failCount"

if ($failCount -gt 0) {
    exit 1
}
