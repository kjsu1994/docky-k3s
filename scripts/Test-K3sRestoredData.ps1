param(
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [string]$BackupPath,
    [string]$SecretName = "docky-secret",
    [string]$OraclePodSelector = "app.kubernetes.io/name=oracle",
    [string]$BackendPodSelector = "app.kubernetes.io/name=backend",
    [string]$RedisPodSelector = "app.kubernetes.io/name=redis",
    [string]$Service = "XEPDB1",
    [int]$MinimumOracleObjectCount = 1,
    [switch]$SkipOracle,
    [switch]$SkipMinioFiles,
    [switch]$SkipRedis,
    [switch]$AllowEmptyRedis
)

$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($Kubeconfig)) {
    if (-not (Test-Path $Kubeconfig)) {
        throw "Kubeconfig not found: $Kubeconfig"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using KUBECONFIG: $env:KUBECONFIG"
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    throw "kubectl not found on PATH."
}

$expectedRedisDbSize = $null
if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    if (-not (Test-Path $BackupPath)) {
        throw "Backup path not found: $BackupPath"
    }
    $resolvedBackupRoot = (Resolve-Path "C:\K3s\backups").Path
    $resolvedBackupPath = (Resolve-Path $BackupPath).Path
    if (-not $resolvedBackupPath.StartsWith($resolvedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "BackupPath must stay under ${resolvedBackupRoot}: $resolvedBackupPath"
    }

    $redisDbSizePath = Join-Path $resolvedBackupPath "redis\redis-dbsize.txt"
    if (Test-Path $redisDbSizePath) {
        $rawRedisSize = (Get-Content -Raw -LiteralPath $redisDbSizePath).Trim()
        $parsedRedisSize = 0
        if ([int]::TryParse($rawRedisSize, [ref]$parsedRedisSize)) {
            $expectedRedisDbSize = $parsedRedisSize
        }
    }
}

function Get-ClusterSecretValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $encoded = & kubectl get secret $SecretName -n $Namespace -o "jsonpath={.data.$Key}"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) {
        throw "Failed to read key $Key from secret $SecretName in namespace $Namespace."
    }
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
}

function Get-FirstPodName {
    param([Parameter(Mandatory = $true)][string]$Selector)

    $pod = (& kubectl get pods -n $Namespace -l $Selector -o "jsonpath={.items[0].metadata.name}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pod)) {
        throw "Pod not found in namespace $Namespace with selector $Selector"
    }
    return $pod
}

function Invoke-PodShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pod,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string]$Container
    )

    $args = @("exec", "-n", $Namespace, $Pod)
    if (-not [string]::IsNullOrWhiteSpace($Container)) {
        $args += @("-c", $Container)
    }
    $args += @("--", "sh", "-lc", $Command)
    $output = & kubectl @args
    if ($LASTEXITCODE -ne 0) {
        throw "Pod command failed on ${Pod}: $Command"
    }
    return $output
}

if (-not $SkipOracle) {
    $systemPassword = Get-ClusterSecretValue -Key "ORACLE_PASSWORD"
    $targetSchema = Get-ClusterSecretValue -Key "ORACLE_APP_USER"
    if ($targetSchema -notmatch '^[A-Za-z][A-Za-z0-9_#$]*$') {
        throw "Invalid Oracle schema identifier in secret: $targetSchema"
    }

    $oraclePod = Get-FirstPodName -Selector $OraclePodSelector
    $runtimeDir = "C:\K3s\runtime"
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $sqlLeaf = "restored-data-oracle-validate-$(Get-Date -Format 'yyyyMMdd-HHmmss').sql"
    $sqlPath = Join-Path $runtimeDir $sqlLeaf
    @(
        "set heading off feedback off pagesize 0",
        "select count(*) from dba_objects where owner = upper('$targetSchema');",
        "exit"
    ) | Set-Content -LiteralPath $sqlPath -Encoding ASCII
    Push-Location -LiteralPath $runtimeDir
    try {
        kubectl cp $sqlLeaf "${Namespace}/${oraclePod}:/tmp/$sqlLeaf"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy Oracle restored-data validation SQL."
    }
    try {
        $objectCountOutput = & kubectl exec -n $Namespace $oraclePod -- sqlplus -s "system/$systemPassword@$Service" "@/tmp/$sqlLeaf"
        if ($LASTEXITCODE -ne 0) {
            throw "Oracle restored-data validation query failed."
        }
    } finally {
        kubectl exec -n $Namespace $oraclePod -- rm -f "/tmp/$sqlLeaf" | Out-Null
        Remove-Item -LiteralPath $sqlPath -Force -ErrorAction SilentlyContinue
    }
    $countText = ($objectCountOutput | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim()
    $objectCount = 0
    if (-not [int]::TryParse($countText, [ref]$objectCount)) {
        throw "Failed to parse Oracle object count: $countText"
    }
    if ($objectCount -lt $MinimumOracleObjectCount) {
        throw "Oracle object count is lower than expected for restored schema. count=$objectCount minimum=$MinimumOracleObjectCount"
    }
    Write-Host "Oracle restored-data check passed. objectCount=$objectCount"
}

if (-not $SkipMinioFiles) {
    $backendPod = Get-FirstPodName -Selector $BackendPodSelector
    $requiredCsvFiles = @(
        "/data/csv_data/Parking_Dataset.csv",
        "/data/csv_data/Restroom_Dataset.csv",
        "/data/csv_data/Library_Dataset.csv",
        "/data/csv_data/Bunker_Dataset.csv",
        "/data/csv_data/Medical_Dataset.csv",
        "/data/csv_data/Medical_Location_Dataset.csv"
    )
    foreach ($file in $requiredCsvFiles) {
        Invoke-PodShell -Pod $backendPod -Container "backend" -Command "test -s '$file'" | Out-Null
    }
    Invoke-PodShell -Pod $backendPod -Container "backend" -Command "test -d /data/streaming" | Out-Null
    Write-Host "MinIO shared-file restored-data checks passed."
}

if (-not $SkipRedis) {
    $redisPod = Get-FirstPodName -Selector $RedisPodSelector
    $redisPing = Invoke-PodShell -Pod $redisPod -Container "redis" -Command "redis-cli PING"
    if (($redisPing | Select-Object -Last 1).Trim() -ne "PONG") {
        throw "Redis PING did not return PONG."
    }
    $dbSizeText = (Invoke-PodShell -Pod $redisPod -Container "redis" -Command "redis-cli DBSIZE" | Select-Object -Last 1).Trim()
    $dbSize = 0
    if (-not [int]::TryParse($dbSizeText, [ref]$dbSize)) {
        throw "Failed to parse Redis DBSIZE: $dbSizeText"
    }
    if ($null -ne $expectedRedisDbSize -and $expectedRedisDbSize -gt 0 -and $dbSize -le 0 -and -not $AllowEmptyRedis) {
        throw "Redis backup had keys but restored Redis DB is empty."
    }
    Write-Host "Redis restored-data check passed. dbSize=$dbSize"
}

Write-Host "K3s restored-data checks passed."
