param(
    [string]$Kubeconfig,
    [string]$Namespace = "docky",
    [string]$IngressNamespace = "ingress-nginx",
    [string]$OutputRoot = "C:\K3s\runtime\diagnostics",
    [int]$TailLines = 300,
    [switch]$IncludeCloudflared
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

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$diagnosticsRoot = [System.IO.Path]::GetFullPath("C:\K3s\runtime\diagnostics").TrimEnd('\')
if (-not ($resolvedOutputRoot.Equals($diagnosticsRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputRoot.StartsWith($diagnosticsRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputRoot must stay under C:\K3s\runtime\diagnostics: $resolvedOutputRoot"
}
$outputDir = Join-Path $resolvedOutputRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$resolvedOutputDir = (Resolve-Path $outputDir).Path
if (-not $resolvedOutputDir.StartsWith($diagnosticsRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Output directory must stay under C:\K3s\runtime\diagnostics: $resolvedOutputDir"
}

function Invoke-DiagnosticCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command
    )

    $path = Join-Path $resolvedOutputDir $Name
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

    $header = @(
        "command: $Name",
        "exitCode: $exitCode",
        "capturedAt: $((Get-Date).ToString("o"))",
        ""
    )
    $text = ($header + ($output | ForEach-Object { $_.ToString() })) -join [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text + [Environment]::NewLine, $utf8NoBom)
}

$metadata = [ordered]@{
    namespace = $Namespace
    ingressNamespace = $IngressNamespace
    outputDir = $resolvedOutputDir
    tailLines = $TailLines
    includeCloudflared = [bool]$IncludeCloudflared
    createdAt = (Get-Date).ToString("o")
    note = "Kubernetes Secret resources are not collected. Review logs before sharing because application logs can contain user data, tokens, or URLs."
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resolvedOutputDir "metadata.json") -Encoding UTF8

Invoke-DiagnosticCommand -Name "kubectl-current-context.txt" -Command { kubectl config current-context }
Invoke-DiagnosticCommand -Name "kubectl-version.txt" -Command { kubectl version --client=true }
Invoke-DiagnosticCommand -Name "nodes-wide.txt" -Command { kubectl get nodes -o wide }
Invoke-DiagnosticCommand -Name "namespaces.txt" -Command { kubectl get namespaces }

foreach ($ns in @($IngressNamespace, $Namespace)) {
    Invoke-DiagnosticCommand -Name "$ns-get-all.txt" -Command { kubectl get all -n $ns -o wide }
    Invoke-DiagnosticCommand -Name "$ns-pods-wide.txt" -Command { kubectl get pods -n $ns -o wide }
    Invoke-DiagnosticCommand -Name "$ns-services-wide.txt" -Command { kubectl get svc -n $ns -o wide }
    Invoke-DiagnosticCommand -Name "$ns-ingress-wide.txt" -Command { kubectl get ingress -n $ns -o wide }
    Invoke-DiagnosticCommand -Name "$ns-pvc.txt" -Command { kubectl get pvc -n $ns -o wide }
    Invoke-DiagnosticCommand -Name "$ns-events.txt" -Command { kubectl get events -n $ns --sort-by=.lastTimestamp }
    Invoke-DiagnosticCommand -Name "$ns-describe-pods.txt" -Command { kubectl describe pods -n $ns }
}

$rolloutTargets = @(
    @{ Namespace = $IngressNamespace; Target = "deployment/ingress-nginx-controller" },
    @{ Namespace = $Namespace; Target = "deployment/redis" },
    @{ Namespace = $Namespace; Target = "statefulset/oracle" },
    @{ Namespace = $Namespace; Target = "statefulset/minio" },
    @{ Namespace = $Namespace; Target = "deployment/backend" },
    @{ Namespace = $Namespace; Target = "deployment/nginx" }
)
if ($IncludeCloudflared) {
    $rolloutTargets += @{ Namespace = $Namespace; Target = "deployment/cloudflared" }
}

foreach ($item in $rolloutTargets) {
    $safeTarget = $item.Target.Replace("/", "-")
    Invoke-DiagnosticCommand -Name "rollout-$($item.Namespace)-$safeTarget.txt" -Command {
        kubectl rollout status $item.Target -n $item.Namespace --timeout=30s
    }
}

$logSelectors = @(
    @{ Name = "backend"; Namespace = $Namespace; Selector = "app.kubernetes.io/name=backend" },
    @{ Name = "nginx"; Namespace = $Namespace; Selector = "app.kubernetes.io/name=nginx" },
    @{ Name = "redis"; Namespace = $Namespace; Selector = "app.kubernetes.io/name=redis" },
    @{ Name = "oracle"; Namespace = $Namespace; Selector = "app.kubernetes.io/name=oracle" },
    @{ Name = "minio"; Namespace = $Namespace; Selector = "app.kubernetes.io/name=minio" },
    @{ Name = "ingress-nginx-controller"; Namespace = $IngressNamespace; Selector = "app.kubernetes.io/component=controller" }
)
if ($IncludeCloudflared) {
    $logSelectors += @{ Name = "cloudflared"; Namespace = $Namespace; Selector = "app.kubernetes.io/name=cloudflared" }
}

foreach ($target in $logSelectors) {
    Invoke-DiagnosticCommand -Name "logs-$($target.Namespace)-$($target.Name).txt" -Command {
        kubectl logs -n $target.Namespace -l $target.Selector --all-containers=true --tail=$TailLines --prefix=true
    }
    Invoke-DiagnosticCommand -Name "logs-previous-$($target.Namespace)-$($target.Name).txt" -Command {
        kubectl logs -n $target.Namespace -l $target.Selector --all-containers=true --tail=$TailLines --prefix=true --previous
    }
}

Write-Host "K3s diagnostics collected: $resolvedOutputDir"
