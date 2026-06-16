param(
    [Parameter(Mandatory = $true)]
    [string]$RdbPath,
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [switch]$ReplaceExisting,
    [switch]$ConfirmRestore
)

$ErrorActionPreference = "Stop"
$confirmEnvName = "K3S_REDIS_RESTORE_CONFIRM"
$confirmEnvValue = "restore-redis-pvc"

if (-not ($ConfirmRestore -or [Environment]::GetEnvironmentVariable($confirmEnvName) -eq $confirmEnvValue)) {
    throw "Refusing to restore Redis PVC. Pass -ConfirmRestore or set $confirmEnvName=$confirmEnvValue."
}
if (-not (Test-Path $RdbPath)) {
    throw "Redis RDB not found: $RdbPath"
}
$resolvedRdb = (Resolve-Path $RdbPath).Path
if (-not $resolvedRdb.StartsWith("C:\K3s\backups", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Redis restore source must be under C:\K3s\backups: $resolvedRdb"
}

function Copy-LocalPathToPod {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemoteSpec
    )
    $resolvedLocal = (Resolve-Path -LiteralPath $LocalPath).Path
    $parent = Split-Path -Parent $resolvedLocal
    $leaf = Split-Path -Leaf $resolvedLocal
    Push-Location -LiteralPath $parent
    try {
        kubectl cp $leaf $RemoteSpec
    } finally {
        Pop-Location
    }
}

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

$restorePodName = "redis-restore"
$restorePod = @"
apiVersion: v1
kind: Pod
metadata:
  name: $restorePodName
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: redis@sha256:f6f58ac6355513c91d7b4d4f3b60b60cfead6ebb94c52643c0135ba5079a28f7
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: redis-data
          mountPath: /data
  volumes:
    - name: redis-data
      persistentVolumeClaim:
        claimName: redis-data
"@

$runtimeDir = "C:\K3s\runtime"
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
$podFile = Join-Path $runtimeDir "redis-restore-pod.yml"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($podFile, $restorePod, $utf8NoBom)

kubectl scale deployment/redis -n $Namespace --replicas=0
if ($LASTEXITCODE -ne 0) { throw "Failed to scale down Redis." }
kubectl rollout status deployment/redis -n $Namespace --timeout=300s
if ($LASTEXITCODE -ne 0) { throw "Redis scale-down wait failed." }

kubectl delete pod $restorePodName -n $Namespace --ignore-not-found=true | Out-Null
kubectl apply -f $podFile
if ($LASTEXITCODE -ne 0) { throw "Failed to create restore pod." }
kubectl wait --for=condition=Ready pod/$restorePodName -n $Namespace --timeout=120s
if ($LASTEXITCODE -ne 0) { throw "Restore pod did not become ready." }

try {
    $existingCount = (& kubectl exec -n $Namespace $restorePodName -- sh -lc "find /data -mindepth 1 -maxdepth 1 | wc -l")
    if ($LASTEXITCODE -ne 0) { throw "Failed to inspect existing Redis PVC content." }
    $countText = ($existingCount | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim()
    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count)) {
        throw "Failed to parse existing Redis PVC file count: $countText"
    }
    if ($count -gt 0 -and -not $ReplaceExisting) {
        throw "Redis PVC is not empty. Re-run with -ReplaceExisting to replace existing Redis persistence files."
    }
    if ($ReplaceExisting) {
        kubectl exec -n $Namespace $restorePodName -- sh -lc "find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
        if ($LASTEXITCODE -ne 0) { throw "Failed to clear existing Redis PVC content." }
    }

    Copy-LocalPathToPod -LocalPath $resolvedRdb -RemoteSpec "${Namespace}/${restorePodName}:/data/dump.rdb"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Redis RDB into PVC." }
    kubectl exec -n $Namespace $restorePodName -- sh -lc "redis-check-rdb /data/dump.rdb"
    if ($LASTEXITCODE -ne 0) { throw "Restored Redis RDB validation failed." }
} finally {
    kubectl delete pod $restorePodName -n $Namespace --ignore-not-found=true | Out-Null
    kubectl scale deployment/redis -n $Namespace --replicas=1 | Out-Null
}

Write-Host "Redis restore submitted from $resolvedRdb"
