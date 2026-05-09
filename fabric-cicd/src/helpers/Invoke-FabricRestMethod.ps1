#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    REST API helper for Fabric endpoints not covered by MicrosoftFabricMgmt.

.DESCRIPTION
    Provides Invoke-FabricRestMethod as a thin, consistent wrapper around
    Invoke-RestMethod with:
      - Automatic token acquisition from the active Az.Accounts session
      - Exponential backoff retry for 429/503/504
      - Long Running Operation (LRO) polling for HTTP 202 responses

    Requires that Set-FabricApiHeaders (or Connect-AzAccount directly) has
    already been called in the same PowerShell session before use.

    Current module gaps covered by callers of this helper:
      - Connection creation / update  (POST /v1/connections)
      - Deployment Pipeline execution (POST /v1/deploymentPipelines/{id}/stages/{id}/deploy)
      - [Future] Git workspace operations

.NOTES
    Dot-sourced by Deploy-FabricEnvironment.ps1. Not a standalone script.
    Token is fetched fresh per call — Az.Accounts caches it until near-expiry.
#>

# ── Constants ──────────────────────────────────────────────────────────────────
$script:FabricResourceUrl = 'https://analysis.windows.net/powerbi/api'
$script:FabricBaseUrl     = 'https://api.fabric.microsoft.com/v1'

# =============================================================================
function Invoke-FabricRestMethod {
<#
.SYNOPSIS
    Calls a Fabric REST API endpoint with retry logic and LRO support.

.PARAMETER Uri
    Full URI of the Fabric API endpoint.
    Use New-FabricUri to construct standard endpoint URIs.

.PARAMETER Method
    HTTP method: Get | Post | Put | Patch | Delete

.PARAMETER Body
    Request body as a JSON string. Omit for GET/DELETE.

.PARAMETER ContentType
    Content-Type header. Defaults to 'application/json; charset=utf-8'.

.PARAMETER WaitForLRO
    When specified, polls the LRO operation URL until completion for HTTP 202 responses.

.PARAMETER MaxRetries
    Maximum number of retry attempts for transient failures (429/503/504). Default: 3.

.PARAMETER RetryBackoffBase
    Base for exponential backoff in seconds. Default: 2 (gives delays: 2s, 4s, 8s).

.EXAMPLE
    # Create a connection
    $body = @{
        displayName       = 'ADLS-Dev'
        connectionDetails = @{ type = 'AzureDataLakeStorage'; path = 'https://...' }
        privacyLevel      = 'Organizational'
    } | ConvertTo-Json -Depth 5

    $result = Invoke-FabricRestMethod `
        -Uri    (New-FabricUri -Path 'connections') `
        -Method Post `
        -Body   $body

.EXAMPLE
    # Trigger a deployment pipeline stage
    $result = Invoke-FabricRestMethod `
        -Uri        (New-FabricUri -Path "deploymentPipelines/$pipelineId/stages/$stageId/deploy") `
        -Method     Post `
        -Body       ($payload | ConvertTo-Json) `
        -WaitForLRO
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')]
        [string]$Method,

        [Parameter()]
        [string]$Body,

        [Parameter()]
        [string]$ContentType = 'application/json; charset=utf-8',

        [Parameter()]
        [switch]$WaitForLRO,

        [Parameter()]
        [int]$MaxRetries = 3,

        [Parameter()]
        [int]$RetryBackoffBase = 2
    )

    # Obtain bearer token from the established Az.Accounts session
    $tokenResponse = Get-AzAccessToken -ResourceUrl $script:FabricResourceUrl -AsSecureString -ErrorAction Stop
    $token         = [System.Net.NetworkCredential]::new([string]::Empty, $tokenResponse.Token).Password

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = $ContentType
    }

    $invokeParams = @{
        Uri                    = $Uri
        Method                 = $Method
        Headers                = $headers
        StatusCodeVariable     = 'statusCode'
        ResponseHeadersVariable = 'responseHeaders'
        SkipHttpErrorCheck     = $true
    }

    if ($Body) {
        $invokeParams['Body'] = $Body
    }

    $retryCount = 0

    do {
        $response = Invoke-RestMethod @invokeParams

        # ── Success responses ─────────────────────────────────────────────────
        if ($statusCode -ge 200 -and $statusCode -lt 300) {

            # HTTP 202 — Long Running Operation
            if ($statusCode -eq 202 -and $WaitForLRO) {
                $operationUrl = ($responseHeaders['Operation-Location'] ?? $responseHeaders['Location']) | Select-Object -First 1
                if ($operationUrl) {
                    Write-Verbose "LRO started. Polling: $operationUrl"
                    return Invoke-FabricLROPoll -OperationUrl $operationUrl -Headers $headers
                }
            }

            return $response
        }

        # ── Retryable errors ──────────────────────────────────────────────────
        if ($statusCode -in @(429, 503, 504) -and $retryCount -lt $MaxRetries) {
            $retryCount++

            $retryAfterHeader = ($responseHeaders['Retry-After'] | Select-Object -First 1)
            $delay = if ($retryAfterHeader -and [int]::TryParse($retryAfterHeader, [ref]$null)) {
                [int]$retryAfterHeader
            } else {
                [Math]::Pow($RetryBackoffBase, $retryCount) + (Get-Random -Minimum 0 -Maximum 2)
            }

            Write-Warning "HTTP $statusCode — retrying in $delay second(s)... (attempt $retryCount/$MaxRetries)"
            Start-Sleep -Seconds $delay
            continue
        }

        # ── Non-retryable errors ──────────────────────────────────────────────
        $errorMessage = if ($response -and $response.PSObject.Properties['message']) {
            $response.message
        } elseif ($response -and $response.PSObject.Properties['error']) {
            $response.error.message
        } else {
            "HTTP $statusCode"
        }

        throw "Fabric API error (HTTP $statusCode) — URI: $Uri — $errorMessage"

    } while ($retryCount -le $MaxRetries)
}

# =============================================================================
function Invoke-FabricLROPoll {
<#
.SYNOPSIS
    Polls a Fabric Long Running Operation URL until it reaches a terminal state.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter()]
        [int]$PollIntervalSeconds = 5,

        [Parameter()]
        [int]$TimeoutMinutes = 30
    )

    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)

    do {
        Start-Sleep -Seconds $PollIntervalSeconds

        $status = Invoke-RestMethod -Uri $OperationUrl -Method Get -Headers $Headers

        switch ($status.status) {
            'Succeeded' {
                Write-Verbose "LRO completed successfully."
                return $status
            }
            { $_ -in @('Failed', 'Cancelled') } {
                $errorDetail = $status.error?.message ?? "Operation $($status.status)"
                throw "Fabric LRO $($status.status): $errorDetail"
            }
            default {
                Write-Verbose "LRO status: $($status.status) — polling..."
            }
        }

        if ((Get-Date) -gt $timeout) {
            throw "Fabric LRO timed out after $TimeoutMinutes minute(s). Operation URL: $OperationUrl"
        }

    } while ($true)
}

# =============================================================================
function New-FabricUri {
<#
.SYNOPSIS
    Constructs a fully-qualified Fabric REST API URI.

.PARAMETER Path
    The API path after /v1/, e.g. 'connections', 'deploymentPipelines/{id}/stages/{stageId}/deploy',
    or 'workspaces/{wsId}/lakehouses'.

.PARAMETER QueryParameters
    Optional hashtable of query string parameters.

.EXAMPLE
    New-FabricUri -Path 'connections'
    # → https://api.fabric.microsoft.com/v1/connections

    New-FabricUri -Path "workspaces/$wsId/lakehouses" -QueryParameters @{ includeInactive = 'true' }
    # → https://api.fabric.microsoft.com/v1/workspaces/{id}/lakehouses?includeInactive=true
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [hashtable]$QueryParameters
    )

    $uri = "$script:FabricBaseUrl/$($Path.TrimStart('/'))"

    if ($QueryParameters -and $QueryParameters.Count -gt 0) {
        $query = ($QueryParameters.GetEnumerator() |
            ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString($_.Value))" }) -join '&'
        $uri = "$uri?$query"
    }

    return $uri
}
