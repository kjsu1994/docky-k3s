param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$DockySecretPath = "C:\K3s\runtime\docky-secret.yml",
    [string]$GhcrSecretPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [string]$BackupPath,
    [string]$Kubeconfig,
    [switch]$IncludeCloudflared,
    [switch]$BootstrapMinio,
    [switch]$SkipRenderSnapshot,
    [switch]$SkipServerDryRun,
    [ValidateSet("auto", "cpu", "gpu")]
    [string]$OllamaGpuMode = "auto",
    [switch]$SkipNvidiaDevicePlugin,
    [int]$OllamaGpuDetectionTimeoutSeconds = 45,
    [switch]$ConfirmApply
)

$ErrorActionPreference = "Stop"

$confirmEnvName = "K3S_APPLY_CONFIRM"
$confirmEnvValue = "apply-k3s"
if (-not ($ConfirmApply -or [Environment]::GetEnvironmentVariable($confirmEnvName) -eq $confirmEnvValue)) {
    throw "Refusing to apply manifests. Pass -ConfirmApply or set $confirmEnvName=$confirmEnvValue."
}

$root = "C:\K3s"
if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

function Test-OllamaGpuResourceAvailable {
    $nodesJson = (& kubectl get nodes -o json 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $nodesJson) {
        return $false
    }

    $nodes = ($nodesJson -join [Environment]::NewLine) | ConvertFrom-Json
    foreach ($node in $nodes.items) {
        $gpu = $node.status.allocatable.'nvidia.com/gpu'
        $gpuCount = 0
        if (-not [string]::IsNullOrWhiteSpace($gpu) -and [int]::TryParse([string]$gpu, [ref]$gpuCount) -and $gpuCount -gt 0) {
            return $true
        }
    }
    return $false
}

function Wait-OllamaGpuResourceAvailable {
    param(
        [int]$TimeoutSeconds = 45,
        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-OllamaGpuResourceAvailable) {
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Install-NvidiaDevicePlugin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$OllamaGpuMode,
        [switch]$UseRuntimeClass
    )

    $pluginRootName = if ($UseRuntimeClass) { "nvidia-device-plugin-runtimeclass" } else { "nvidia-device-plugin" }
    $pluginRoot = Join-Path $Root $pluginRootName
    if (-not (Test-Path $pluginRoot)) {
        $message = "NVIDIA device plugin manifest root not found: $pluginRoot"
        if ($OllamaGpuMode -eq "auto") {
            Write-Warning $message
            return $false
        }
        throw $message
    }

    Write-Host "Installing NVIDIA device plugin from $pluginRoot"
    kubectl apply -k $pluginRoot
    if ($LASTEXITCODE -ne 0) {
        $message = "Failed to apply NVIDIA device plugin."
        if ($OllamaGpuMode -eq "auto") {
            Write-Warning "$message Falling back to CPU if no GPU is already allocatable."
            return $false
        }
        throw $message
    }

    kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        $message = "NVIDIA device plugin rollout did not complete."
        if ($OllamaGpuMode -eq "auto") {
            Write-Warning "$message Falling back to CPU if no GPU is already allocatable."
            return $false
        }
        throw $message
    }

    return $true
}

function Resolve-AppRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$OllamaGpuMode,
        [bool]$UseRuntimeClass = $false
    )

    $cpuRoot = switch ($Environment) {
        "staging" { Join-Path $Root "overlays\staging" }
        "docker-desktop" { Join-Path $Root "overlays\docker-desktop" }
        default { Join-Path $Root "manifests" }
    }

    if ($OllamaGpuMode -eq "cpu") {
        Write-Host "Ollama GPU mode: cpu. Using CPU manifest root: $cpuRoot"
        return $cpuRoot
    }

    $gpuOverlayName = if ($UseRuntimeClass) { "$Environment-ollama-gpu-runtimeclass" } else { "$Environment-ollama-gpu" }
    $gpuRoot = Join-Path $Root "overlays\$gpuOverlayName"
    if ($OllamaGpuMode -eq "gpu") {
        Write-Host "Ollama GPU mode: gpu. Using GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    if (Test-OllamaGpuResourceAvailable) {
        Write-Host "Ollama GPU mode: auto detected nvidia.com/gpu. Using GPU manifest root: $gpuRoot"
        return $gpuRoot
    }

    Write-Host "Ollama GPU mode: auto found no allocatable nvidia.com/gpu. Falling back to CPU manifest root: $cpuRoot"
    return $cpuRoot
}

$gateArgs = @(
    "-Environment", $Environment,
    "-DockySecretPath", $DockySecretPath,
    "-GhcrSecretPath", $GhcrSecretPath
)
if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    $gateArgs += @("-BackupPath", $BackupPath)
}
if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    $gateArgs += @("-Kubeconfig", $Kubeconfig)
}
if ($IncludeCloudflared) {
    $gateArgs += "-IncludeCloudflared"
}
if ($BootstrapMinio) {
    $gateArgs += "-BootstrapMinio"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sCutoverGate.ps1") @gateArgs
if ($LASTEXITCODE -ne 0) {
    throw "Cutover gate failed."
}

$useOllamaRuntimeClass = $false
if ($OllamaGpuMode -ne "cpu" -and -not $SkipNvidiaDevicePlugin) {
    $pluginInstalled = Install-NvidiaDevicePlugin -Root $root -OllamaGpuMode $OllamaGpuMode
    if ($pluginInstalled) {
        if (Wait-OllamaGpuResourceAvailable -TimeoutSeconds $OllamaGpuDetectionTimeoutSeconds) {
            Write-Host "NVIDIA GPU resource detected on the target cluster."
        } else {
            Write-Warning "NVIDIA device plugin is installed, but no allocatable nvidia.com/gpu resource was detected. Retrying with RuntimeClass/nvidia."
            $runtimeClassPluginInstalled = Install-NvidiaDevicePlugin -Root $root -OllamaGpuMode $OllamaGpuMode -UseRuntimeClass
            if ($runtimeClassPluginInstalled -and (Wait-OllamaGpuResourceAvailable -TimeoutSeconds $OllamaGpuDetectionTimeoutSeconds)) {
                Write-Host "NVIDIA GPU resource detected with RuntimeClass/nvidia."
                $useOllamaRuntimeClass = $true
            } else {
                if (-not $runtimeClassPluginInstalled -and $OllamaGpuMode -eq "auto") {
                    Write-Warning "Restoring NVIDIA device plugin without RuntimeClass/nvidia before CPU fallback."
                    Install-NvidiaDevicePlugin -Root $root -OllamaGpuMode $OllamaGpuMode | Out-Null
                }
                $message = "NVIDIA device plugin is installed, but no allocatable nvidia.com/gpu resource was detected."
                if ($OllamaGpuMode -eq "gpu") {
                    throw $message
                }
                Write-Warning "$message Ollama will use the CPU manifest root."
            }
        }
    }
} elseif ($OllamaGpuMode -ne "cpu" -and $SkipNvidiaDevicePlugin) {
    Write-Host "Skipping NVIDIA device plugin install because -SkipNvidiaDevicePlugin was passed."
}

if ($OllamaGpuMode -eq "gpu" -and -not (Test-OllamaGpuResourceAvailable)) {
    throw "Ollama GPU mode was forced, but the cluster does not advertise allocatable nvidia.com/gpu."
}

$appRoot = Resolve-AppRoot -Environment $Environment -Root $root -OllamaGpuMode $OllamaGpuMode -UseRuntimeClass $useOllamaRuntimeClass

if (-not $SkipRenderSnapshot) {
    $renderArgs = @(
        "-Environment", $Environment,
        "-OllamaGpuMode", $OllamaGpuMode
    )
    if ($useOllamaRuntimeClass) {
        $renderArgs += "-UseOllamaRuntimeClass"
    }
    if ($IncludeCloudflared) {
        $renderArgs += "-IncludeCloudflared"
    }
    if ($BootstrapMinio) {
        $renderArgs += "-IncludeMinioBootstrapJob"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Export-K3sRenderedManifests.ps1") @renderArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to export rendered manifest snapshot."
    }
}

kubectl apply -f (Join-Path $root "manifests\namespace.yml")
if ($LASTEXITCODE -ne 0) { throw "Failed to apply namespace." }

kubectl apply -f (Join-Path $root "ingress-nginx\namespace.yml")
if ($LASTEXITCODE -ne 0) { throw "Failed to apply ingress-nginx namespace." }

if (-not $SkipServerDryRun) {
    $serverDryRunArgs = @(
        "-Environment", $Environment,
        "-DockySecretPath", $DockySecretPath,
        "-GhcrSecretPath", $GhcrSecretPath,
        "-OllamaGpuMode", $OllamaGpuMode
    )
    if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
        $serverDryRunArgs += @("-Kubeconfig", $Kubeconfig)
    }
    if ($IncludeCloudflared) {
        $serverDryRunArgs += "-IncludeCloudflared"
    }
    if ($BootstrapMinio) {
        $serverDryRunArgs += "-BootstrapMinio"
    }
    if ($SkipNvidiaDevicePlugin) {
        $serverDryRunArgs += "-SkipNvidiaDevicePlugin"
    }
    if ($useOllamaRuntimeClass) {
        $serverDryRunArgs += "-UseOllamaRuntimeClass"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\Test-K3sServerDryRun.ps1") @serverDryRunArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Server dry-run failed."
    }
}

kubectl apply -f $DockySecretPath
if ($LASTEXITCODE -ne 0) { throw "Failed to apply docky runtime secret: $DockySecretPath" }

kubectl apply -f $GhcrSecretPath
if ($LASTEXITCODE -ne 0) { throw "Failed to apply GHCR image pull secret: $GhcrSecretPath" }

kubectl apply -k (Join-Path $root "ingress-nginx")
if ($LASTEXITCODE -ne 0) { throw "Failed to apply ingress-nginx." }

kubectl apply -k $appRoot
if ($LASTEXITCODE -ne 0) { throw "Failed to apply app manifests: $appRoot" }

if ($BootstrapMinio) {
    kubectl apply -f (Join-Path $root "jobs\minio-bootstrap-job.yml")
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply MinIO bootstrap job." }
}

if ($IncludeCloudflared) {
    kubectl apply -k (Join-Path $root "cloudflared")
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply cloudflared." }
}

Write-Host "Apply sequence submitted for $Environment."
