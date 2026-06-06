#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently provisions Fabric shareable cloud connections.

.DESCRIPTION
    Supported types: AzureDevOpsSourceControl.
    Payload structure conforms to:
      POST /v1/connections
      https://learn.microsoft.com/en-us/rest/api/fabric/core/connections/create-connection

    Credential source: deployment SPN (ClientId / ClientSecret / TenantId).

    Returns hashtable of connection name → GUID for downstream use (connectionRef resolution).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter()]
    [string]$ClientId = '',

    [Parameter()]
    [string]$ClientSecret = '',

    [Parameter()]
    [string]$TenantId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

# ── Helper: unwrap fab api JSON envelope and validate HTTP status ──────────────
# fab api exits with code 0 for any completed HTTP request, including 4xx/5xx.
# The actual HTTP status code is embedded in the response envelope.
# This function unwraps the body AND throws on non-2xx status.
function Invoke-FabApiCall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter()]          [string]   $OpDesc = 'fab api call',
        [Parameter()]          [int]      $MaxRetries = 1
    )

    $result = Invoke-FabCli -Arguments $Arguments `
        -MaxRetries $MaxRetries -AllowNonZeroExit -JsonOutput

    if ($result.ExitCode -ne 0) {
        throw "$OpDesc failed (exit $($result.ExitCode)): $($result.Stderr) $($result.Output)"
    }

    if ($null -eq $result.Output) { return $null }

    # Unwrap envelope — newer fab: { status_code, text }
    #                  older fab:  { result: { data: [{ status_code, text }] } }
    $statusCode = $null
    $body = $null

    if ($result.Output.PSObject.Properties.Name -contains 'status_code') {
        $statusCode = $result.Output.status_code
        $body = $result.Output.text
    }
    elseif ($result.Output.PSObject.Properties.Name -contains 'result' -and
        $result.Output.result.PSObject.Properties.Name -contains 'data' -and
        $result.Output.result.data.Count -gt 0) {
        $entry = $result.Output.result.data[0]
        $statusCode = if ($entry.PSObject.Properties.Name -contains 'status_code') { $entry.status_code } else { $null }
        $body = $entry.text
    }
    else {
        # No envelope — return raw (some fab versions omit it for simple GET)
        $body = $result.Output
    }

    if ($null -ne $statusCode -and $statusCode -notin @(200, 201, 202, 204)) {
        $errDetail = if ($body -and $body -is [PSCustomObject]) {
            if ($body.PSObject.Properties.Name -contains 'message') { $body.message }
            elseif ($body.PSObject.Properties.Name -contains 'errorCode') { $body.errorCode }
            else { $body | ConvertTo-Json -Compress -Depth 3 -ErrorAction SilentlyContinue }
        }
        else { "$body" }
        throw "$OpDesc returned HTTP $statusCode : $errDetail"
    }

    if ($body -is [string] -and $body -eq '(Empty)') { return $null }
    return $body
}

# ── Helper: find an existing connection by display name ───────────────────────
# Uses GET /v1/connections rather than 'fab get .connections/<name>.Connection'
# because the path-based syntax is unreliable for connections.
function Get-FabConnectionByName {
    param([Parameter(Mandatory)] [string] $DisplayName)

    $body = Invoke-FabApiCall -Arguments @('api', 'connections') -OpDesc "GET connections"
    if ($null -eq $body) { return $null }

    $items = if ($body.PSObject.Properties.Name -contains 'value') { $body.value } else { @($body) }
    return @($items) | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
}

function Validate-FabConnectionPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Payload,
        [Parameter(Mandatory)] [string]    $ConnectionName
    )

    if ($Payload.connectionDetails -and $Payload.connectionDetails.type -eq 'AzureDevOpsSourceControl') {
        $cd = $Payload.connectionDetails

        if ($null -eq $cd.creationMethod -or $cd.creationMethod -ne 'AzureDevOpsSourceControl.Contents') {
            throw "Connection '$ConnectionName': AzureDevOpsSourceControl must use creationMethod 'AzureDevOpsSourceControl.Contents'."
        }

        if ($cd.PSObject.Properties.Name -contains 'path') {
            throw "Connection '$ConnectionName': connectionDetails.path is not supported for AzureDevOpsSourceControl create operations. Use connectionDetails.parameters with name 'url'."
        }

        if (-not $cd.parameters -or $cd.parameters.Count -eq 0) {
            throw "Connection '$ConnectionName': AzureDevOpsSourceControl payload must contain connectionDetails.parameters with a 'url' parameter."
        }

        $urlParam = $cd.parameters | Where-Object {
            $entryName = try { $_.name } catch { $null }
            if ($null -eq $entryName -and $_ -is [System.Collections.IDictionary]) {
                $entryName = if ($_.ContainsKey('name')) { $_['name'] } else { $null }
            }
            $entryName -eq 'url'
        }

        if (-not $urlParam) {
            throw "Connection '$ConnectionName': AzureDevOpsSourceControl payload must include a 'url' parameter under connectionDetails.parameters."
        }
    }

}

# ── Guard ──────────────────────────────────────────────────────────────────────
$hasConnections = $Config.PSObject.Properties.Name -contains 'connections'
if (-not $hasConnections -or $null -eq $Config.connections -or $Config.connections.Count -eq 0) {
    Write-Host "  No connections defined in config - skipping."
    return @{}
}

$connectionsMap = @{}   # name → GUID

foreach ($connConfig in $Config.connections) {
    $connName = $connConfig.name
    $connType = $connConfig.type
    $connFabPath = ".connections/$connName.Connection"

    Write-Host "  Processing connection: $connName ($connType)"

    # ── 1. Check existence via REST API ───────────────────────────────────────
    $existing = $null
    try {
        $existing = Get-FabConnectionByName -DisplayName $connName
    }
    catch {
        Write-Warning "    Could not list connections (will attempt create): $_"
    }

    $exists = $null -ne $existing
    Write-Host "    Existence check: $($exists ? "Found (ID: $($existing.id))" : 'Not found')"

    if ($exists) {
        $connectionsMap[$connName] = $existing.id
    }
    else {
        # ── 2. Build creation payload ──────────────────────────────────────────
        # Payload structure: POST /v1/connections
        # https://learn.microsoft.com/en-us/rest/api/fabric/core/connections/create-connection
        #
        # connectivityType enum: ShareableCloud | PersonalCloud | OnPremisesGateway
        #                        | VirtualNetworkDataGateway | OnPremisesGatewayPersonal
        # NOTE: value is "ShareableCloud" — no space. A space causes HTTP 400 silently.

        $payload = $null

        switch ($connType) {

            'AzureDevOpsSourceControl' {
                $connPath = if ($connConfig.PSObject.Properties.Name -contains 'path' -and $connConfig.path) {
                    $connConfig.path
                }
                else {
                    throw "Connection '$connName' (AzureDevOpsSourceControl) requires 'path' " +
                    "(format: https://dev.azure.com/{org}/{project}/_git/{repo}/)."
                }

                # Azure DevOps automation uses SPN credentials only.
                # If credentialType is omitted, default to ServicePrincipal.
                $credType = if ($connConfig.PSObject.Properties.Name -contains 'credentialType' -and $connConfig.credentialType) {
                    $connConfig.credentialType
                }
                else { 'ServicePrincipal' }

                if ($credType -ne 'ServicePrincipal') {
                    throw "Connection '$connName' (AzureDevOpsSourceControl) must use credentialType 'ServicePrincipal' for automation."
                }

                if (-not $ClientId -or -not $ClientSecret -or -not $TenantId) {
                    throw "Connection '$connName' (AzureDevOpsSourceControl / ServicePrincipal) requires -ClientId, -ClientSecret, and -TenantId."
                }

                $creds = [ordered]@{
                    credentialType           = 'ServicePrincipal'
                    servicePrincipalClientId = $ClientId
                    servicePrincipalSecret   = $ClientSecret
                    tenantId                 = $TenantId
                }

                $payload = [ordered]@{
                    connectivityType  = 'ShareableCloud'
                    displayName       = $connName
                    connectionDetails = [ordered]@{
                        type           = 'AzureDevOpsSourceControl'
                        creationMethod = 'AzureDevOpsSourceControl.Contents'
                        parameters     = @(
                            [ordered]@{ dataType = 'Text'; name = 'url'; value = $connPath }
                        )
                    }
                    credentialDetails = [ordered]@{
                        singleSignOnType     = 'None'
                        connectionEncryption = 'NotEncrypted'
                        skipTestConnection   = $false
                        credentials          = $creds
                    }
                    allowConnectionUsageInGateway = $true
                    privacyLevel      = 'Organizational'
                }
            }

            default {
                throw "Unsupported connection type '$connType'. Supported: AzureDevOpsSourceControl."
            }
        }

        # ── 3. Create ──────────────────────────────────────────────────────────
        Validate-FabConnectionPayload -Payload $payload -ConnectionName $connName

        $payloadJson = $payload | ConvertTo-Json -Depth 10 -Compress
        Write-Host "    Creating connection: $connName"
        Write-Verbose "    Payload: $payloadJson"

        try {
            $created = Invoke-FabApiCall `
                -Arguments @('api', '-X', 'post', 'connections', '-i', $payloadJson) `
                -OpDesc    "POST connections/$connName"

            $connId = if ($created -and $created.PSObject.Properties.Name -contains 'id') {
                $created.id
            }
            else { $null }

            if ($connId) {
                $connectionsMap[$connName] = $connId
                Write-Host "    Connection created: $connName (ID: $connId)"
            }
            else {
                # Creation appeared to succeed but returned no ID — re-query
                Write-Warning "    Create response contained no ID. Re-querying by name..."
                $refetch = Get-FabConnectionByName -DisplayName $connName
                if ($refetch) {
                    $connectionsMap[$connName] = $refetch.id
                    Write-Host "    Connection ID resolved by re-query: $($refetch.id)"
                }
                else {
                    Write-Warning "    Connection '$connName' not found after create. ConnectionRef resolution will fail."
                }
            }
        }
        catch {
            $errText = "$_"
            if ($errText -match 'AlreadyExists|already exists|DuplicateObjectName') {
                Write-Warning "    Connection '$connName' already exists (concurrent create or stale list). Re-querying..."
                $refetch = Get-FabConnectionByName -DisplayName $connName
                if ($refetch) {
                    $connectionsMap[$connName] = $refetch.id
                    Write-Host "    Connection ID resolved: $($refetch.id)"
                }
            }
            else {
                throw
            }
        }
    }

    # ── 4. Configure role assignments ──────────────────────────────────────────
    $hasRoles = $connConfig.PSObject.Properties.Name -contains 'roles'
    $roles = if ($hasRoles) { @($connConfig.roles | Where-Object { $_ }) } else { @() }

    if ($roles.Count -eq 0) {
        Write-Verbose "    No role assignments defined for connection: $connName"
        continue
    }

    if (-not $connectionsMap.ContainsKey($connName)) {
        Write-Warning "    Skipping role assignment for '$connName' — connection ID not available."
        continue
    }

    Write-Host "    Configuring role assignments for: $connName"

    # Use REST API directly: GET /v1/connections/{id}/roleAssignments
    # fab acl commands target the same endpoint internally but require the path syntax
    # to resolve cleanly; using fab api is explicit and avoids path resolution issues.
    $connId = $connectionsMap[$connName]
    $currentBody = Invoke-FabApiCall `
        -Arguments @('api', "connections/$connId/roleAssignments") `
        -OpDesc    "GET connections/$connId/roleAssignments"

    $currentAssignments = if ($currentBody -and $currentBody.PSObject.Properties.Name -contains 'value') {
        @($currentBody.value)
    }
    else { @() }

    foreach ($roleConfig in $roles) {
        $identity = $roleConfig.identity
        $desiredRole = $roleConfig.role
        $shouldRemove = ($roleConfig.PSObject.Properties.Name -contains 'remove') -and ($roleConfig.remove -eq $true)
        $principalType = if ($roleConfig.PSObject.Properties.Name -contains 'principalType' -and $roleConfig.principalType) {
            $roleConfig.principalType
        }
        else {
            throw "Connection '$connName' role assignment for identity '$identity' is missing required field 'principalType'. Set principalType to: User | Group | ServicePrincipal."
        }
        if ($principalType -notin @('Group', 'User', 'ServicePrincipal')) {
            throw "Connection '$connName' role assignment for identity '$identity' has invalid principalType '$principalType'. Must be: Group | User | ServicePrincipal."
        }

        $existing = $currentAssignments | Where-Object {
            $_.principal -and $_.principal.id -eq $identity
        } | Select-Object -First 1

        if ($shouldRemove) {
            if ($existing) {
                Write-Host "      Removing $desiredRole for: $identity"
                Invoke-FabApiCall `
                    -Arguments @('api', '-X', 'delete', "connections/$connId/roleAssignments/$($existing.id)") `
                    -OpDesc    "DELETE connections/$connId/roleAssignments/$($existing.id)" | Out-Null
            }
            else {
                Write-Verbose "      Role assignment not found (already removed): $desiredRole → $identity"
            }
            continue
        }

        $existingRole = if ($existing -and $existing.PSObject.Properties.Name -contains 'role') { $existing.role } else { $null }

        if ($existing -and $existingRole -eq $desiredRole) {
            Write-Verbose "      Assignment exists, no changes: $desiredRole → $identity"
            continue
        }

        Write-Host "      $(if ($existing) { "Updating $existingRole → $desiredRole" } else { "Assigning $desiredRole" }) for: $identity"

        if ($existing) {
            $updatePayload = @{ role = $desiredRole } | ConvertTo-Json -Compress
            Invoke-FabApiCall `
                -Arguments @('api', '-X', 'patch', "connections/$connId/roleAssignments/$($existing.id)", '-i', $updatePayload) `
                -OpDesc    "PATCH connections/$connId/roleAssignments/$($existing.id)" | Out-Null
        }
        else {
            $principal = [ordered]@{ id = $identity; type = $principalType }

            $createBody = [ordered]@{
                principal = $principal
                role      = $desiredRole
            } | ConvertTo-Json -Compress

            Invoke-FabApiCall `
                -Arguments @('api', '-X', 'post', "connections/$connId/roleAssignments", '-i', $createBody) `
                -OpDesc    "POST connections/$connId/roleAssignments" | Out-Null
        }
    }
}

Write-Host "  Connections deployment complete. Processed: $($connectionsMap.Count) connection(s)."
return $connectionsMap