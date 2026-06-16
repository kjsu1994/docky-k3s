param(
    [Parameter(Mandatory = $true)]
    [string]$MinioDataBackupPath,
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [string]$HelperImage,
    [switch]$ReplaceExisting,
    [switch]$ConfirmRestore
)

$ErrorActionPreference = "Stop"
$confirmEnvName = "K3S_MINIO_RESTORE_CONFIRM"
$confirmEnvValue = "restore-minio-pvc"

if (-not ($ConfirmRestore -or [Environment]::GetEnvironmentVariable($confirmEnvName) -eq $confirmEnvValue)) {
    throw "Refusing to restore MinIO PVC. Pass -ConfirmRestore or set $confirmEnvName=$confirmEnvValue."
}
if (-not (Test-Path $MinioDataBackupPath)) {
    throw "MinIO backup path not found: $MinioDataBackupPath"
}
$resolvedBackup = (Resolve-Path $MinioDataBackupPath).Path
if (-not $resolvedBackup.StartsWith("C:\K3s\backups", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "MinIO restore source must be under C:\K3s\backups: $resolvedBackup"
}

function Copy-LocalDirectoryContentsToPod {
    param(
        [Parameter(Mandatory = $true)][string]$LocalDirectory,
        [Parameter(Mandatory = $true)][string]$RemoteSpec
    )
    $resolvedLocal = (Resolve-Path -LiteralPath $LocalDirectory).Path
    Push-Location -LiteralPath $resolvedLocal
    try {
        kubectl cp . $RemoteSpec
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

if ([string]::IsNullOrWhiteSpace($HelperImage)) {
    $HelperImage = (& kubectl get deployment/backend -n $Namespace -o "jsonpath={.spec.template.spec.containers[?(@.name=='backend')].image}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($HelperImage)) {
        throw "Failed to determine helper image from deployment/backend. Pass -HelperImage with a reviewed Docky backend image."
    }
}
Write-Host "Using MinIO restore helper image: $HelperImage"

$restorePodName = "minio-restore"
$restorePod = @"
apiVersion: v1
kind: Pod
metadata:
  name: $restorePodName
  namespace: $Namespace
spec:
  imagePullSecrets:
    - name: ghcr-pull-secret
  restartPolicy: Never
  containers:
    - name: restore
      image: $HelperImage
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: minio-data
          mountPath: /restore
  volumes:
    - name: minio-data
      persistentVolumeClaim:
        claimName: minio-data
"@

$runtimeDir = "C:\K3s\runtime"
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
$podFile = Join-Path $runtimeDir "minio-restore-pod.yml"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($podFile, $restorePod, $utf8NoBom)

kubectl scale statefulset/minio -n $Namespace --replicas=0
if ($LASTEXITCODE -ne 0) { throw "Failed to scale down MinIO." }
kubectl rollout status statefulset/minio -n $Namespace --timeout=300s
if ($LASTEXITCODE -ne 0) { throw "MinIO scale-down wait failed." }

kubectl delete pod $restorePodName -n $Namespace --ignore-not-found=true | Out-Null
kubectl apply -f $podFile
if ($LASTEXITCODE -ne 0) { throw "Failed to create restore pod." }
kubectl wait --for=condition=Ready pod/$restorePodName -n $Namespace --timeout=120s
if ($LASTEXITCODE -ne 0) { throw "Restore pod did not become ready." }

try {
    if ($ReplaceExisting) {
        kubectl exec -n $Namespace $restorePodName -- sh -lc "find /restore -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
        if ($LASTEXITCODE -ne 0) { throw "Failed to clear existing MinIO PVC content." }
    }
    Copy-LocalDirectoryContentsToPod -LocalDirectory $resolvedBackup -RemoteSpec "${Namespace}/${restorePodName}:/restore"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy MinIO backup into PVC." }
} finally {
    kubectl delete pod $restorePodName -n $Namespace --ignore-not-found=true | Out-Null
    kubectl scale statefulset/minio -n $Namespace --replicas=1 | Out-Null
}

Write-Host "MinIO restore submitted from $resolvedBackup"
