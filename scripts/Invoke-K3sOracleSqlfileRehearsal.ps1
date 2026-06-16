param(
    [Parameter(Mandatory = $true)]
    [string]$DumpFile,
    [Parameter(Mandatory = $true)]
    [string]$SystemPassword,
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [string]$OraclePodSelector = "app.kubernetes.io/name=oracle",
    [string]$Service = "XEPDB1",
    [string]$OutputDir = "C:\K3s\backups\oracle-rehearsal"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DumpFile)) {
    throw "Dump file not found: $DumpFile"
}
$resolvedDump = (Resolve-Path $DumpFile).Path
if (-not $resolvedDump.StartsWith("C:\K3s\backups\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Oracle SQLFILE rehearsal source must be under C:\K3s\backups: $resolvedDump"
}
if ([string]::IsNullOrWhiteSpace($SystemPassword)) {
    throw "SystemPassword is required."
}
$resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir).TrimEnd('\')
if (-not ($resolvedOutputDir.Equals("C:\K3s\backups", [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputDir.StartsWith("C:\K3s\backups\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputDir must stay under C:\K3s\backups: $resolvedOutputDir"
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
$pod = (kubectl get pod -n $Namespace -l $OraclePodSelector -o jsonpath='{.items[0].metadata.name}')
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pod)) {
    throw "Oracle pod not found in namespace $Namespace with selector $OraclePodSelector"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$remoteDir = "/tmp/docky-rehearsal-$stamp"
$directoryName = "DOCKY_REHEARSAL_DIR"
$dumpName = Split-Path -Leaf $resolvedDump
$sqlFile = "docky-$stamp-restore-rehearsal.sql"
$importLog = "docky-$stamp-impdp-sqlfile.log"
$setupSql = Join-Path $resolvedOutputDir "oracle-rehearsal-setup-$stamp.sql"
$cleanupSql = Join-Path $resolvedOutputDir "oracle-rehearsal-cleanup-$stamp.sql"
$parFile = Join-Path $resolvedOutputDir "oracle-rehearsal-import-$stamp.par"

@(
    "whenever sqlerror exit sql.sqlcode",
    "create or replace directory $directoryName as '$remoteDir';",
    "exit"
) | Set-Content -LiteralPath $setupSql -Encoding ASCII

@(
    "whenever sqlerror exit sql.sqlcode",
    "drop directory $directoryName;",
    "exit"
) | Set-Content -LiteralPath $cleanupSql -Encoding ASCII

@(
    "userid=`"system/$SystemPassword@$Service`"",
    "directory=$directoryName",
    "dumpfile=$dumpName",
    "sqlfile=$sqlFile",
    "logfile=$importLog"
) | Set-Content -LiteralPath $parFile -Encoding ASCII

kubectl exec -n $Namespace $pod -- bash -lc "rm -rf $remoteDir; mkdir -p $remoteDir; chmod 777 $remoteDir"
if ($LASTEXITCODE -ne 0) { throw "Failed to prepare remote rehearsal directory." }

kubectl cp $resolvedDump "${Namespace}/${pod}:${remoteDir}/${dumpName}"
if ($LASTEXITCODE -ne 0) { throw "Failed to copy dump file to Oracle pod." }
kubectl cp $setupSql "${Namespace}/${pod}:/tmp/docky-rehearsal-setup.sql"
if ($LASTEXITCODE -ne 0) { throw "Failed to copy setup SQL." }
kubectl cp $cleanupSql "${Namespace}/${pod}:/tmp/docky-rehearsal-cleanup.sql"
if ($LASTEXITCODE -ne 0) { throw "Failed to copy cleanup SQL." }
kubectl cp $parFile "${Namespace}/${pod}:/tmp/docky-rehearsal-import.par"
if ($LASTEXITCODE -ne 0) { throw "Failed to copy import parfile." }

try {
    kubectl exec -n $Namespace $pod -- bash -lc "sqlplus -s `"system/$SystemPassword@$Service`" @/tmp/docky-rehearsal-setup.sql"
    if ($LASTEXITCODE -ne 0) { throw "Oracle directory setup failed." }

    kubectl exec -n $Namespace $pod -- bash -lc "impdp parfile=/tmp/docky-rehearsal-import.par"
    if ($LASTEXITCODE -ne 0) { throw "Oracle SQLFILE rehearsal failed." }

    kubectl cp "${Namespace}/${pod}:${remoteDir}/${sqlFile}" (Join-Path $resolvedOutputDir $sqlFile)
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy rehearsal SQLFILE output." }
    kubectl cp "${Namespace}/${pod}:${remoteDir}/${importLog}" (Join-Path $resolvedOutputDir $importLog)
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy rehearsal log output." }
} finally {
    kubectl exec -n $Namespace $pod -- bash -lc "sqlplus -s `"system/$SystemPassword@$Service`" @/tmp/docky-rehearsal-cleanup.sql; rm -rf $remoteDir /tmp/docky-rehearsal-setup.sql /tmp/docky-rehearsal-cleanup.sql /tmp/docky-rehearsal-import.par" | Out-Null
}

Write-Host "Oracle SQLFILE rehearsal complete: $resolvedOutputDir"
