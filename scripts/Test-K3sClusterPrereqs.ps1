param(
    [string]$Kubeconfig,
    [ValidateSet("staging", "production", "docker-desktop")]
    [string]$Environment = "staging",
    [string]$StorageClassName,
    [switch]$SkipAuthChecks,
    [switch]$WarnOnly
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

function Add-Finding {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [string]$Name,
        [string]$Status,
        [string]$Detail
    )

    $Target.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

function Invoke-KubectlJson {
    param([string[]]$KubectlArgs)

    $json = & kubectl @KubectlArgs -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        return $null
    }
    return (($json -join [Environment]::NewLine) | ConvertFrom-Json)
}

$findings = New-Object System.Collections.Generic.List[object]

$context = (& kubectl config current-context 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($context)) {
    Add-Finding -Target $findings -Name "current-context" -Status "FAIL" -Detail "kubectl current-context is not set."
} else {
    Add-Finding -Target $findings -Name "current-context" -Status "PASS" -Detail $context
}

$nodes = Invoke-KubectlJson -KubectlArgs @("get", "nodes")
if ($null -eq $nodes -or $null -eq $nodes.items -or @($nodes.items).Count -eq 0) {
    Add-Finding -Target $findings -Name "nodes" -Status "FAIL" -Detail "No Kubernetes nodes are readable."
} else {
    $readyNodes = 0
    $nodeSummaries = New-Object System.Collections.Generic.List[string]
    foreach ($node in @($nodes.items)) {
        $ready = @($node.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1)
        $isReady = $ready -and $ready.status -eq "True"
        if ($isReady) { $readyNodes += 1 }
        $os = $node.status.nodeInfo.operatingSystem
        $arch = $node.status.nodeInfo.architecture
        $nodeSummaries.Add("$($node.metadata.name):ready=$isReady,os=$os,arch=$arch") | Out-Null
        if ($os -ne "linux") {
            Add-Finding -Target $findings -Name "node-os-$($node.metadata.name)" -Status "FAIL" -Detail "Expected linux node, got $os."
        }
        if ($arch -ne "amd64") {
            Add-Finding -Target $findings -Name "node-arch-$($node.metadata.name)" -Status "WARN" -Detail "Oracle XE image is normally validated on amd64; got $arch."
        }
    }
    $status = if ($readyNodes -gt 0) { "PASS" } else { "FAIL" }
    Add-Finding -Target $findings -Name "nodes-ready" -Status $status -Detail ($nodeSummaries -join "; ")
}

$storageClasses = Invoke-KubectlJson -KubectlArgs @("get", "storageclass")
if ($null -eq $storageClasses -or $null -eq $storageClasses.items -or @($storageClasses.items).Count -eq 0) {
    Add-Finding -Target $findings -Name "storageclass" -Status "FAIL" -Detail "No StorageClass found. PVCs will remain Pending."
} else {
    $selectedStorageClass = $null
    if (-not [string]::IsNullOrWhiteSpace($StorageClassName)) {
        $selectedStorageClass = @($storageClasses.items | Where-Object { $_.metadata.name -eq $StorageClassName } | Select-Object -First 1)
    } else {
        $selectedStorageClass = @($storageClasses.items | Where-Object {
            $_.metadata.annotations."storageclass.kubernetes.io/is-default-class" -eq "true" -or
            $_.metadata.annotations."storageclass.beta.kubernetes.io/is-default-class" -eq "true"
        } | Select-Object -First 1)
    }

    if ($null -eq $selectedStorageClass) {
        $names = @($storageClasses.items | ForEach-Object { $_.metadata.name }) -join ", "
        $detail = if ([string]::IsNullOrWhiteSpace($StorageClassName)) {
            "No default StorageClass found. Existing classes: $names"
        } else {
            "Requested StorageClass not found: $StorageClassName. Existing classes: $names"
        }
        Add-Finding -Target $findings -Name "storageclass" -Status "FAIL" -Detail $detail
    } else {
        Add-Finding -Target $findings -Name "storageclass" -Status "PASS" -Detail "name=$($selectedStorageClass.metadata.name), provisioner=$($selectedStorageClass.provisioner)"
    }
}

$corednsPods = Invoke-KubectlJson -KubectlArgs @("get", "pods", "-n", "kube-system", "-l", "k8s-app=kube-dns")
if ($null -eq $corednsPods -or $null -eq $corednsPods.items -or @($corednsPods.items).Count -eq 0) {
    Add-Finding -Target $findings -Name "coredns" -Status "WARN" -Detail "No CoreDNS pods found by label k8s-app=kube-dns."
} else {
    $notReady = @($corednsPods.items | Where-Object { $_.status.phase -ne "Running" })
    if ($notReady.Count -gt 0) {
        Add-Finding -Target $findings -Name "coredns" -Status "FAIL" -Detail "Some CoreDNS pods are not Running."
    } else {
        Add-Finding -Target $findings -Name "coredns" -Status "PASS" -Detail "CoreDNS pods are Running."
    }
}

if (-not $SkipAuthChecks) {
    $authChecks = @(
        @{ Verb = "create"; Resource = "namespaces"; Namespace = $null },
        @{ Verb = "create"; Resource = "secrets"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "configmaps"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "services"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "deployments.apps"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "statefulsets.apps"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "persistentvolumeclaims"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "ingresses.networking.k8s.io"; Namespace = "docky" },
        @{ Verb = "create"; Resource = "jobs.batch"; Namespace = "docky" }
    )
    foreach ($check in $authChecks) {
        $authArgs = @("auth", "can-i", $check.Verb, $check.Resource)
        if ($check.Namespace) {
            $authArgs += @("-n", $check.Namespace)
        }
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $allowed = (& kubectl @authArgs 2>$null)
        $authExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        $name = "auth-$($check.Verb)-$($check.Resource)"
        if ($authExitCode -eq 0 -and ($allowed -join "").Trim() -eq "yes") {
            Add-Finding -Target $findings -Name $name -Status "PASS" -Detail "allowed"
        } else {
            Add-Finding -Target $findings -Name $name -Status "FAIL" -Detail "not allowed"
        }
    }
}

$findings | Format-Table -AutoSize

$failures = @($findings | Where-Object { $_.Status -eq "FAIL" })
if ($failures.Count -gt 0) {
    if ($WarnOnly) {
        Write-Warning "K3s cluster prerequisite checks have failures."
    } else {
        throw "K3s cluster prerequisite checks failed."
    }
} else {
    Write-Host "K3s cluster prerequisite checks passed for $Environment."
}
