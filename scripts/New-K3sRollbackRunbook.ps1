param(
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "production",
    [string]$Root = "C:\K3s",
    [string]$Kubeconfig = "C:\K3s\runtime\kubeconfig.yml",
    [string]$BaseUrl,
    [string]$OutputRoot = "C:\K3s\runtime\runbooks",
    [switch]$IncludeCloudflared
)

$ErrorActionPreference = "Stop"

function New-CodeBlock {
    param([Parameter(Mandatory = $true)][string]$Text)
    $nl = [Environment]::NewLine
    return "~~~powershell$nl$Text$nl~~~"
}

if (-not (Test-Path $Root)) {
    throw "K3s root not found: $Root"
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = switch ($Environment) {
        "docker-desktop" { "http://localhost:8080" }
        "staging" { "https://staging.docky.co.kr" }
        default { "https://docky.co.kr" }
    }
}

$resolvedRoot = (Resolve-Path $Root).Path
$templatePath = Join-Path $resolvedRoot "templates\rollback-runbook.ko.md"
if (-not (Test-Path $templatePath)) {
    throw "Rollback runbook template not found: $templatePath"
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot "runtime")).TrimEnd('\')
if (-not ($resolvedOutputRoot.Equals($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputRoot.StartsWith($runtimeRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputRoot must stay under C:\K3s\runtime: $resolvedOutputRoot"
}
if (-not (Test-Path $resolvedOutputRoot)) {
    New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null
}

$nl = [Environment]::NewLine
$line = [char]96
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputPath = Join-Path $resolvedOutputRoot "rollback-$Environment-$stamp.md"

$cloudflaredFlag = if ($IncludeCloudflared) { " $line$nl  -IncludeCloudflared" } else { "" }
$cloudflaredScaleDown = if ($IncludeCloudflared) {
    "kubectl --kubeconfig $Kubeconfig scale deployment/cloudflared -n docky --replicas=0"
} else {
    "# Skip this step when cloudflared was not applied."
}

$diagnosticCommand = @(
    "C:\K3s\scripts\Collect-K3sDiagnostics.ps1 $line",
    "  -Kubeconfig $Kubeconfig$cloudflaredFlag"
) -join $nl

$pauseCommand = @(
    "kubectl --kubeconfig $Kubeconfig scale deployment/nginx -n docky --replicas=0",
    "kubectl --kubeconfig $Kubeconfig scale deployment/backend -n docky --replicas=0",
    $cloudflaredScaleDown,
    "",
    "kubectl --kubeconfig $Kubeconfig get pods -n docky -o wide",
    "kubectl --kubeconfig $Kubeconfig get ingress -n docky -o wide"
) -join $nl

$validationCommand = @(
    "C:\K3s\scripts\Test-K3sHttpSmoke.ps1 $line",
    "  -BaseUrl $BaseUrl $line",
    "  -IncludeWebSocket"
) -join $nl

$template = Get-Content -Raw -Encoding UTF8 -LiteralPath $templatePath
$content = $template.
    Replace("__CREATED_AT__", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")).
    Replace("__ENVIRONMENT__", $Environment).
    Replace("__BASE_URL__", $BaseUrl).
    Replace("__KUBECONFIG__", $Kubeconfig).
    Replace("__DIAGNOSTIC_COMMAND__", (New-CodeBlock -Text $diagnosticCommand)).
    Replace("__PAUSE_COMMAND__", (New-CodeBlock -Text $pauseCommand)).
    Replace("__VALIDATION_COMMAND__", (New-CodeBlock -Text $validationCommand))

$content = [regex]::Replace($content, "(\r?\n){3,}", "$nl$nl")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outputPath, $content + [Environment]::NewLine, $utf8NoBom)
Write-Host "K3s rollback runbook written: $outputPath"
