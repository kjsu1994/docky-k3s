param(
    [Parameter(Mandatory = $true)]
    [string]$Username,
    [Parameter(Mandatory = $true)]
    [string]$Token,
    [string]$OutputPath = "C:\K3s\runtime\ghcr-pull-secret.yml",
    [string]$Namespace = "docky",
    [string]$SecretName = "ghcr-pull-secret",
    [string]$Kubeconfig
)

$ErrorActionPreference = "Stop"

function Assert-PathUnder {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if (-not ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + "\", [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "${Message}: $candidateFull"
    }
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

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
Assert-PathUnder -Candidate $resolvedOutputPath -AllowedRoot "C:\K3s\runtime" -Message "OutputPath must stay under C:\K3s\runtime"
$outputDir = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$yaml = & kubectl create secret docker-registry $SecretName `
    --docker-server=ghcr.io `
    --docker-username=$Username `
    --docker-password=$Token `
    --namespace=$Namespace `
    --dry-run=client `
    -o yaml

if ($LASTEXITCODE -ne 0 -or -not $yaml) {
    throw "Failed to render GHCR imagePullSecret."
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedOutputPath, ($yaml -join [Environment]::NewLine) + [Environment]::NewLine, $utf8NoBom)
Write-Host "Wrote image pull secret manifest: $resolvedOutputPath"
