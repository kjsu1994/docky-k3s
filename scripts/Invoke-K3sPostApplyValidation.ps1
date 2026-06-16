param(
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [string]$BaseUrl,
    [int]$RuntimeTimeoutSeconds = 600,
    [int]$SmokeTimeoutSeconds = 15,
    [switch]$IncludeCloudflared,
    [switch]$IncludeWebSocket,
    [switch]$IncludeIot,
    [switch]$IncludeExternalServices,
    [switch]$SkipHttpSmoke,
    [switch]$SkipInClusterConnectivity,
    [switch]$SkipDiagnostics,
    [switch]$CollectDiagnosticsOnlyOnFailure
)

$ErrorActionPreference = "Stop"
$root = "C:\K3s"

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

$failed = $false
try {
    $runtimeArgs = @(
        "-Namespace", $Namespace,
        "-TimeoutSeconds", $RuntimeTimeoutSeconds
    )
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $runtimeArgs += @("-Kubeconfig", $Kubeconfig)
    }
    if ($IncludeCloudflared) {
        $runtimeArgs += "-IncludeCloudflared"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sRuntime.ps1") @runtimeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime rollout validation failed."
    }

    if (-not $SkipInClusterConnectivity) {
        $connectivityArgs = @(
            "-Namespace", $Namespace
        )
        if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
            $connectivityArgs += @("-Kubeconfig", $Kubeconfig)
        }
        if ($IncludeExternalServices) {
            $connectivityArgs += "-IncludeExternalServices"
        }
        if (-not $IncludeIot) {
            $connectivityArgs += "-SkipIot"
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sInClusterConnectivity.ps1") @connectivityArgs
        if ($LASTEXITCODE -ne 0) {
            throw "In-cluster connectivity validation failed."
        }
    }

    if (-not $SkipHttpSmoke) {
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
            throw "BaseUrl is required unless -SkipHttpSmoke is passed."
        }
        $smokeArgs = @(
            "-BaseUrl", $BaseUrl,
            "-TimeoutSeconds", $SmokeTimeoutSeconds
        )
        if ($IncludeWebSocket) {
            $smokeArgs += "-IncludeWebSocket"
        }
        if ($IncludeIot) {
            $smokeArgs += "-IncludeIot"
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sHttpSmoke.ps1") @smokeArgs
        if ($LASTEXITCODE -ne 0) {
            throw "HTTP smoke validation failed."
        }
    }
} catch {
    $failed = $true
    Write-Host "K3s post-apply validation failed: $($_.Exception.Message)"
} finally {
    $shouldCollectDiagnostics = -not $SkipDiagnostics -and (-not $CollectDiagnosticsOnlyOnFailure -or $failed)
    if ($shouldCollectDiagnostics) {
        $diagnosticArgs = @(
            "-Namespace", $Namespace
        )
        if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
            $diagnosticArgs += @("-Kubeconfig", $Kubeconfig)
        }
        if ($IncludeCloudflared) {
            $diagnosticArgs += "-IncludeCloudflared"
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Collect-K3sDiagnostics.ps1") @diagnosticArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Diagnostics collection failed."
        }
    }
}

if ($failed) {
    exit 1
}

Write-Host "K3s post-apply validation passed."
