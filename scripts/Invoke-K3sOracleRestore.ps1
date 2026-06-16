param(
    [Parameter(Mandatory = $true)]
    [string]$DumpFile,
    [string]$SystemPassword,
    [string]$SourceSchema,
    [string]$TargetSchema,
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [string]$OraclePodSelector = "app.kubernetes.io/name=oracle",
    [string]$Service = "XEPDB1",
    [string]$SecretName = "docky-secret",
    [ValidateSet("SKIP", "APPEND", "TRUNCATE", "REPLACE")]
    [string]$TableExistsAction = "REPLACE",
    [string]$OutputDir = "C:\K3s\backups\oracle-restore",
    [switch]$ReadCredentialsFromClusterSecret,
    [switch]$AllowDataPumpWarnings,
    [switch]$SkipBackendScaleDown,
    [switch]$ConfirmRestore
)

$ErrorActionPreference = "Stop"
$confirmEnvName = "K3S_ORACLE_RESTORE_CONFIRM"
$confirmEnvValue = "restore-oracle-schema"

if (-not ($ConfirmRestore -or [Environment]::GetEnvironmentVariable($confirmEnvName) -eq $confirmEnvValue)) {
    throw "Refusing to restore Oracle schema. Pass -ConfirmRestore or set $confirmEnvName=$confirmEnvValue."
}
if (-not (Test-Path $DumpFile)) {
    throw "Oracle dump file not found: $DumpFile"
}

$resolvedDump = (Resolve-Path $DumpFile).Path
if (-not $resolvedDump.StartsWith("C:\K3s\backups", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Oracle restore source must be under C:\K3s\backups: $resolvedDump"
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

function Get-ClusterSecretValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $encoded = & kubectl get secret $SecretName -n $Namespace -o "jsonpath={.data.$Key}"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) {
        throw "Failed to read key $Key from secret $SecretName in namespace $Namespace."
    }
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
}

function Assert-OracleIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -notmatch '^[A-Za-z][A-Za-z0-9_#$]*$') {
        throw "Invalid Oracle identifier for ${Name}: $Value"
    }
}

if ($ReadCredentialsFromClusterSecret) {
    $SystemPassword = Get-ClusterSecretValue -Key "ORACLE_PASSWORD"
    $TargetSchema = Get-ClusterSecretValue -Key "ORACLE_APP_USER"
}

if ([string]::IsNullOrWhiteSpace($SystemPassword)) {
    throw "SystemPassword is required unless -ReadCredentialsFromClusterSecret is used."
}
if ([string]::IsNullOrWhiteSpace($TargetSchema)) {
    throw "TargetSchema is required unless -ReadCredentialsFromClusterSecret is used."
}
if ([string]::IsNullOrWhiteSpace($SourceSchema)) {
    $SourceSchema = $TargetSchema
}

Assert-OracleIdentifier -Name "SourceSchema" -Value $SourceSchema
Assert-OracleIdentifier -Name "TargetSchema" -Value $TargetSchema

New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
$runtimeDir = "C:\K3s\runtime"
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

$pod = (& kubectl get pod -n $Namespace -l $OraclePodSelector -o jsonpath='{.items[0].metadata.name}')
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pod)) {
    throw "Oracle pod not found in namespace $Namespace with selector $OraclePodSelector"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$remoteDir = "/tmp/docky-restore-$stamp"
$directoryName = "DOCKY_RESTORE_DIR"
$dumpName = Split-Path -Leaf $resolvedDump
$importLog = "docky-$stamp-impdp-restore.log"
$setupSql = Join-Path $runtimeDir "oracle-restore-setup-$stamp.sql"
$cleanupSql = Join-Path $runtimeDir "oracle-restore-cleanup-$stamp.sql"
$validateSql = Join-Path $runtimeDir "oracle-restore-validate-$stamp.sql"
$parFile = Join-Path $runtimeDir "oracle-restore-import-$stamp.par"
$sequenceCleanupSql = Join-Path $runtimeDir "oracle-restore-drop-sequences-$stamp.sql"
$previousBackendReplicas = $null

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

function Copy-PodPathToLocal {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteSpec,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )
    $parent = Split-Path -Parent $LocalPath
    $leaf = Split-Path -Leaf $LocalPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Push-Location -LiteralPath $parent
    try {
        kubectl cp $RemoteSpec $leaf
    } finally {
        Pop-Location
    }
}

@(
    "whenever sqlerror exit sql.sqlcode",
    "create or replace directory $directoryName as '$remoteDir';",
    "grant read, write on directory $directoryName to $TargetSchema;",
    "exit"
) | Set-Content -LiteralPath $setupSql -Encoding ASCII

@(
    "whenever sqlerror exit sql.sqlcode",
    "drop directory $directoryName;",
    "exit"
) | Set-Content -LiteralPath $cleanupSql -Encoding ASCII

@(
    "set heading off feedback off pagesize 0",
    "select count(*) from dba_objects where owner = upper('$TargetSchema');",
    "exit"
) | Set-Content -LiteralPath $validateSql -Encoding ASCII

@(
    "set heading off feedback off pagesize 0 verify off trimspool on",
    "spool /tmp/docky-restore-drop-sequences-generated.sql",
    ('select ''drop sequence '' || sequence_owner || ''.'' || sequence_name || '';'' from dba_sequences where sequence_owner = upper(''{0}'') and sequence_name not like ''ISEQ$$_%'';' -f $TargetSchema),
    "spool off",
    "@/tmp/docky-restore-drop-sequences-generated.sql",
    "exit"
) | Set-Content -LiteralPath $sequenceCleanupSql -Encoding ASCII

$parLines = New-Object System.Collections.Generic.List[string]
$parLines.Add("userid=`"system/$SystemPassword@$Service`"")
$parLines.Add("directory=$directoryName")
$parLines.Add("dumpfile=$dumpName")
$parLines.Add("logfile=$importLog")
$parLines.Add("schemas=$SourceSchema")
if ($SourceSchema -ne $TargetSchema) {
    $parLines.Add("remap_schema=${SourceSchema}:${TargetSchema}")
}
$parLines.Add("table_exists_action=$TableExistsAction")
$parLines.Add("metrics=y")
$parLines.Add("logtime=all")
$parLines.Add("transform=segment_attributes:n")
$parLines | Set-Content -LiteralPath $parFile -Encoding ASCII

try {
    if (-not $SkipBackendScaleDown) {
        try {
            $previousBackendReplicas = (& kubectl get deployment/backend -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null)
        } catch {
            $previousBackendReplicas = $null

        }
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($previousBackendReplicas)) {
            kubectl scale deployment/backend -n $Namespace --replicas=0
            if ($LASTEXITCODE -ne 0) { throw "Failed to scale down backend before Oracle restore." }
            kubectl rollout status deployment/backend -n $Namespace --timeout=300s
            if ($LASTEXITCODE -ne 0) { throw "Backend scale-down wait failed." }
        }
    }

    kubectl exec -n $Namespace $pod -- bash -lc "rm -rf $remoteDir; mkdir -p $remoteDir; chmod 777 $remoteDir"
    if ($LASTEXITCODE -ne 0) { throw "Failed to prepare remote Oracle restore directory." }

    Copy-LocalPathToPod -LocalPath $resolvedDump -RemoteSpec "${Namespace}/${pod}:${remoteDir}/${dumpName}"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle dump file to pod." }
    Copy-LocalPathToPod -LocalPath $setupSql -RemoteSpec "${Namespace}/${pod}:/tmp/docky-restore-setup.sql"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle restore setup SQL." }
    Copy-LocalPathToPod -LocalPath $cleanupSql -RemoteSpec "${Namespace}/${pod}:/tmp/docky-restore-cleanup.sql"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle restore cleanup SQL." }
    Copy-LocalPathToPod -LocalPath $validateSql -RemoteSpec "${Namespace}/${pod}:/tmp/docky-restore-validate.sql"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle restore validate SQL." }
    Copy-LocalPathToPod -LocalPath $parFile -RemoteSpec "${Namespace}/${pod}:/tmp/docky-restore-import.par"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle restore parfile." }
    if ($TableExistsAction -eq "REPLACE") {
        Copy-LocalPathToPod -LocalPath $sequenceCleanupSql -RemoteSpec "${Namespace}/${pod}:/tmp/docky-restore-drop-sequences.sql"
        if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle sequence cleanup SQL." }
    }

    kubectl exec -n $Namespace $pod -- bash -lc "sqlplus -s `"system/$SystemPassword@$Service`" @/tmp/docky-restore-setup.sql"
    if ($LASTEXITCODE -ne 0) { throw "Oracle restore directory setup failed." }

    if ($TableExistsAction -eq "REPLACE") {
        kubectl exec -n $Namespace $pod -- bash -lc "sqlplus -s `"system/$SystemPassword@$Service`" @/tmp/docky-restore-drop-sequences.sql"
        if ($LASTEXITCODE -ne 0) { throw "Oracle sequence cleanup before restore failed." }
    }

    kubectl exec -n $Namespace $pod -- bash -lc "impdp parfile=/tmp/docky-restore-import.par"
    $impdpExit = $LASTEXITCODE
    if ($impdpExit -ne 0) {
        if (-not ($AllowDataPumpWarnings -and $impdpExit -eq 5)) {
            throw "Oracle Data Pump import failed with exit code $impdpExit."
        }
        Write-Warning "Oracle Data Pump import completed with warnings. Review the import log."
    }

    Copy-PodPathToLocal -RemoteSpec "${Namespace}/${pod}:${remoteDir}/${importLog}" -LocalPath (Join-Path $resolvedOutputDir $importLog)
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy Oracle restore import log." }

    $objectCount = (& kubectl exec -n $Namespace $pod -- bash -lc "sqlplus -s `"system/$SystemPassword@$Service`" @/tmp/docky-restore-validate.sql")
    if ($LASTEXITCODE -ne 0) { throw "Oracle restore validation query failed." }
    $countText = ($objectCount | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim()
    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count) -or $count -le 0) {
        throw "Oracle restore validation found no objects for schema $TargetSchema."
    }
    Write-Host "Oracle restore validation object count for ${TargetSchema}: $count"
} finally {
    kubectl exec -n $Namespace $pod -- bash -lc "sqlplus -s `"system/$SystemPassword@$Service`" @/tmp/docky-restore-cleanup.sql; rm -rf $remoteDir /tmp/docky-restore-setup.sql /tmp/docky-restore-cleanup.sql /tmp/docky-restore-validate.sql /tmp/docky-restore-import.par /tmp/docky-restore-drop-sequences.sql /tmp/docky-restore-drop-sequences-generated.sql" | Out-Null
    Remove-Item -LiteralPath $setupSql, $cleanupSql, $validateSql, $parFile, $sequenceCleanupSql -Force -ErrorAction SilentlyContinue
    if (-not $SkipBackendScaleDown -and -not [string]::IsNullOrWhiteSpace($previousBackendReplicas)) {
        kubectl scale deployment/backend -n $Namespace --replicas=$previousBackendReplicas | Out-Null
    }
}

Write-Host "Oracle restore completed from $resolvedDump"
