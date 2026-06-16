param(
    [string]$BaseUrl = "http://localhost:8080",
    [int[]]$AllowedApiStatuses = @(200, 204, 301, 302, 400, 401, 403, 404),
    [int[]]$AllowedProxyStatuses = @(200, 204, 301, 302, 400, 401, 403, 404, 405),
    [int]$TimeoutSeconds = 15,
    [switch]$IncludeWebSocket,
    [switch]$IncludeIot,
    [switch]$FailOnServerErrors = $true
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [int[]]$AllowedStatuses,
        [hashtable]$Headers = @{}
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSeconds -Headers $Headers
        $status = [int]$response.StatusCode
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        } else {
            throw "Request failed without HTTP response: $Url - $($_.Exception.Message)"
        }
    }

    if ($FailOnServerErrors -and $status -ge 500) {
        throw "Server/upstream error for ${Url}: HTTP $status"
    }
    if ($AllowedStatuses -notcontains $status) {
        throw "Unexpected status for ${Url}: HTTP $status"
    }
    Write-Host "$Url -> HTTP $status"
}

$normalizedBase = $BaseUrl.TrimEnd("/")

$checks = @(
    @{ Path = "/"; Allowed = @(200) },
    @{ Path = "/index.html"; Allowed = @(200) },
    @{ Path = "/sw.js"; Allowed = @(200, 404) },
    @{ Path = "/api/queue/status"; Allowed = $AllowedApiStatuses },
    @{ Path = "/api/auth/refresh"; Allowed = $AllowedApiStatuses },
    @{ Path = "/api/image/view?path=__k3s_smoke_missing__"; Allowed = $AllowedApiStatuses },
    @{ Path = "/api/chat/file/view?path=__k3s_smoke_missing__"; Allowed = $AllowedApiStatuses },
    @{ Path = "/api/streaming/videos"; Allowed = $AllowedApiStatuses },
    @{ Path = "/api/streaming/videos/0/hls/index.m3u8"; Allowed = $AllowedApiStatuses },
    @{ Path = "/api/admin/streaming/videos"; Allowed = $AllowedApiStatuses },
    @{ Path = "/oauth2/authorization/google"; Allowed = $AllowedProxyStatuses },
    @{ Path = "/login/oauth2/code/google"; Allowed = $AllowedProxyStatuses },
    @{ Path = "/upload-files/__k3s_smoke_missing__"; Allowed = $AllowedProxyStatuses }
)

foreach ($check in $checks) {
    Invoke-SmokeRequest -Url "$normalizedBase$($check.Path)" -AllowedStatuses $check.Allowed
}

if ($IncludeWebSocket) {
    $headers = @{
        Upgrade = "websocket"
        Connection = "Upgrade"
        "Sec-WebSocket-Key" = "dGhlIHNhbXBsZSBub25jZQ=="
        "Sec-WebSocket-Version" = "13"
    }
    Invoke-SmokeRequest -Url "$normalizedBase/ws/" -AllowedStatuses @(101, 400, 401, 403, 404) -Headers $headers
}

if ($IncludeIot) {
    Invoke-SmokeRequest -Url "$normalizedBase/iot/" -AllowedStatuses $AllowedProxyStatuses
    Invoke-SmokeRequest -Url "$normalizedBase/iot-api/" -AllowedStatuses $AllowedProxyStatuses
}

Write-Host "HTTP smoke checks completed."
