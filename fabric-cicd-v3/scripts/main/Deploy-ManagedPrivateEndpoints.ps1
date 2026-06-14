#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently provisions resource-agnostic Managed Private Endpoints (MPEs)
    for Fabric workspaces.

.DESCRIPTION
    For each workspace with a 'managedPrivateEndpoints' block:
      - Checks if the MPE already exists via 'fab get'
      - Creates it if missing via 'fab create'
      - Warns (does not auto-fix) if an existing MPE's target resource/subresource
        drifts from config — MPEs are not patchable; recreation requires manual
        delete + re-run.
      - If connectionState.status is 'Pending' and 'autoApprovalEnabled: true',
        approves the private endpoint connection on the target resource via
        'az network private-endpoint-connection approve'.

    Auto-approval works for any resource type supported by the az CLI
    'az network private-endpoint-connection' command family. The connection
    name on the target resource follows the Fabric-managed pattern:
        {workspaceId}.{mpeName}-conn

    Requires az CLI to be available on the agent when autoApprovalEnabled is
    used. The deploying SPN must have write access to privateEndpointConnections
    on the target resource (e.g. Key Vault Contributor for vault targets).

    Called by Deploy-FabricEnvironment.ps1 as the final deployment step.
    Assumes 'fab auth login' has already been called in the same shell session.

.PARAMETER Config
    Validated PSCustomObject from Read-EnvironmentConfig.

.PARAMETER WorkspaceMap
    Hashtable of workspace name → workspace GUID produced by Deploy-Workspaces.ps1.

.PARAMETER Environment
    Target environment (dev | tst | prd).

.PARAMETER ClientId
    SPN application (client) ID. Required for az CLI login when auto-approval is used.

.PARAMETER ClientSecret
    SPN client secret. Required for az CLI login when auto-approval is used.

.PARAMETER TenantId
    Entra ID tenant ID. Required for az CLI login when auto-approval is used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

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

# ── Helper: normalize 'fab get -q {...}' output for ManagedPrivateEndpoint ─────
# 'fab get <mpe-path>' without -q returns the list of queryable field NAMES,
# not their values. Always use -q with a projection. The envelope is:
#   { timestamp, status, command, result: { data: [ { <projected fields> } ] } }
# This extracts result.data[0] as the projected object.
function Get-MpeDetails {
    param($RawOutput)

    if ($null -eq $RawOutput) { return $null }

    $obj = $RawOutput

    if ($obj -is [System.Array]) {
        if ($obj.Count -eq 0) { return $null }
        $obj = $obj[0]
    }
    if ($null -eq $obj) { return $null }

    if ($obj.PSObject.Properties.Name -contains 'result' -and
        $null -ne $obj.result -and
        $obj.result.PSObject.Properties.Name -contains 'data') {
        $obj = $obj.result.data
    }

    if ($obj -is [System.Array]) {
        if ($obj.Count -eq 0) { return $null }
        $obj = $obj[0]
    }

    return $obj
}

# ── Helper: safe flat property getter ─────────────────────────────────────────
function Get-MpeProp {
    param($Obj, [string]$Key, $Default = $null)

    if ($null -eq $Obj) { return $Default }
    if ($Obj.PSObject.Properties.Name -notcontains $Key) { return $Default }
    $val = $Obj.$Key
    if ($null -eq $val) { return $Default }
    return $val
}

# ── Helper: lazy az CLI login ──────────────────────────────────────────────────
# Called only when auto-approval is actually needed. Logs in once per script
# invocation using the deployment SPN credentials.
$script:azLoggedIn = $false
function Initialize-AzCli {
    if ($script:azLoggedIn) { return }

    if (-not $ClientId -or -not $ClientSecret -or -not $TenantId) {
        throw "Auto-approval via az CLI requires -ClientId, -ClientSecret, and -TenantId."
    }

    Write-Host "    Authenticating az CLI for auto-approval..."
    $loginOut = az login --service-principal `
        -u $ClientId `
        -p $ClientSecret `
        --tenant $TenantId 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "az login failed: $loginOut"
    }

    $script:azLoggedIn = $true
    Write-Host "    az CLI authenticated."
}

# ── Helper: generic private endpoint connection approval via az CLI ────────────
# Connection name pattern (Fabric-managed): {workspaceId}.{mpeName}-conn
# Works for any resource type supported by az network private-endpoint-connection.
#
# $TargetResourceId  — full ARM resource ID of the target resource
# $WorkspaceId       — Fabric workspace GUID (used to construct connection name)
# $MpeName           — MPE display name (used to construct connection name)
function Approve-ManagedPrivateEndpointConnection {
    param(
        [Parameter(Mandatory)] [string] $TargetResourceId,
        [Parameter(Mandatory)] [string] $WorkspaceId,
        [Parameter(Mandatory)] [string] $MpeName
    )

    # Parse resource ID segments:
    # /subscriptions/{sub}/resourceGroups/{rg}/providers/{ns}/{type}/{name}
    $segments = $TargetResourceId.TrimStart('/') -split '/'
    # segments: 0=subscriptions, 1={sub}, 2=resourceGroups, 3={rg},
    #           4=providers, 5={ns}, 6={type}, 7={resourceName}
    if ($segments.Count -lt 8) {
        throw "Cannot parse targetPrivateLinkResourceId '$TargetResourceId' — expected at least 8 path segments."
    }
    $subscription = $segments[1]
    $resourceGroup = $segments[3]
    $resourceType = "$($segments[5])/$($segments[6])"   # e.g. Microsoft.KeyVault/vaults
    $resourceName = $segments[7]                          # e.g. ndpl-necp01-weu-fdev-kvt

    # Fabric-managed PE connection name: {workspaceId}.{mpeName}-conn
    $expectedConnName = "$WorkspaceId.$MpeName-conn"

    Write-Host "    Listing private endpoint connections on '$resourceName' (type: $resourceType)..."

    $listJson = az network private-endpoint-connection list `
        --resource-group $resourceGroup `
        --name $resourceName `
        --type $resourceType `
        --subscription $subscription 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "az network private-endpoint-connection list failed: $listJson"
    }

    $connections = $listJson | ConvertFrom-Json

    # Match by connection name (last segment of id, or name property if present)
    $target = @($connections | Where-Object {
            $connName = ($_.id -split '/')[-1]
            $connName -eq $expectedConnName
        }) | Select-Object -First 1

    if (-not $target) {
        Write-Warning "    Connection '$expectedConnName' not found on '$resourceName'. Available connections:"
        foreach ($c in $connections) {
            $connName = ($c.id -split '/')[-1]
            $status = $c.properties.privateLinkServiceConnectionState.status
            Write-Host "      '$connName' [$status]"
        }
        return $false
    }

    $currentStatus = $target.properties.privateLinkServiceConnectionState.status
    $targetConnName = ($target.id -split '/')[-1]

    if ($currentStatus -eq 'Approved') {
        Write-Host "    Connection '$targetConnName' already Approved."
        return $true
    }

    Write-Host "    Approving '$targetConnName' (current: $currentStatus)..."

    $approveOut = az network private-endpoint-connection approve `
        --resource-group $resourceGroup `
        --resource-name $resourceName `
        --name $targetConnName `
        --type $resourceType `
        --subscription $subscription `
        --description "Approved by fabric-cicd-v3 (Deploy-ManagedPrivateEndpoints)" 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "az network private-endpoint-connection approve failed: $approveOut"
    }

    Write-Host "    Approved: '$targetConnName'."
    return $true
}

# ── JMESPath projection for fab get ───────────────────────────────────────────
# Without -q, 'fab get' on ManagedPrivateEndpoint returns field NAMES, not values.
$mpeQuery = '{id: id, provisioningState: provisioningState, connectionStateStatus: connectionState.status, connectionStateDescription: connectionState.description, connectionStateActionsRequired: connectionState.actionsRequired, name: name, targetPrivateLinkResourceId: targetPrivateLinkResourceId, targetSubresourceType: targetSubresourceType}'

# ── Collect all MPE work items ──────────────────────────────────────────────────
$workItems = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($workspaceConfig in $Config.workspaces) {
    $hasMpe = $workspaceConfig.PSObject.Properties.Name -contains 'managedPrivateEndpoints'
    if (-not $hasMpe -or -not $workspaceConfig.managedPrivateEndpoints) { continue }

    foreach ($mpe in @($workspaceConfig.managedPrivateEndpoints | Where-Object { $_ })) {
        $workItems.Add([PSCustomObject]@{
                WorkspaceName = $workspaceConfig.name
                Mpe           = $mpe
            })
    }
}

if ($workItems.Count -eq 0) {
    Write-Host "  No managedPrivateEndpoints defined in config - skipping."
    return
}

$processedCount = 0

foreach ($item in $workItems) {
    $wsName = $item.WorkspaceName
    $mpe = $item.Mpe
    $mpeName = $mpe.name

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  Workspace '$wsName' not in workspace map. Skipping MPE '$mpeName'."
        continue
    }

    $wsId = $WorkspaceMap[$wsName]
    $mpeFabPath = "$wsName.Workspace/.managedprivateendpoints/$mpeName.ManagedPrivateEndpoint"
    $autoApprove = if ($mpe.PSObject.Properties.Name -contains 'autoApprovalEnabled' -and $null -ne $mpe.autoApprovalEnabled) {
        [bool]$mpe.autoApprovalEnabled
    }
    else { $false }

    Write-Host ""
    Write-Host "  [$wsName] Processing MPE: $mpeName"

    # ── 1. Check existence ────────────────────────────────────────────────────
    $getResult = Invoke-FabCli -Arguments @('get', $mpeFabPath, '-q', $mpeQuery) -AllowNonZeroExit -MaxRetries 1 -JsonOutput
    $exists = $getResult.ExitCode -eq 0 -and $null -ne $getResult.Output
    $current = $null

    if ($exists) {
        $current = Get-MpeDetails -RawOutput $getResult.Output
        if ($null -eq $current) {
            Write-Warning "    'fab get' returned exit 0 but no parseable object for '$mpeName'. Raw:"
            Write-Warning "    $($getResult.Output | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)"
            $exists = $false
        }
    }

    if ($exists) {
        $currentProvState = Get-MpeProp -Obj $current -Key 'provisioningState'      -Default '(unknown)'
        $currentConnStatus = Get-MpeProp -Obj $current -Key 'connectionStateStatus'   -Default '(unknown)'
        Write-Host "    MPE exists. provisioningState=$currentProvState, connectionState=$currentConnStatus"

        # ── Drift check ─────────────────────────────────────────────────────────
        $currentTargetId = Get-MpeProp -Obj $current -Key 'targetPrivateLinkResourceId' -Default ''
        $currentSubresource = Get-MpeProp -Obj $current -Key 'targetSubresourceType'       -Default ''

        $drift = @()
        if ($currentTargetId -ne $mpe.targetPrivateLinkResourceId) {
            $drift += "targetPrivateLinkResourceId (current: '$currentTargetId', desired: '$($mpe.targetPrivateLinkResourceId)')"
        }
        if ($currentSubresource -ne $mpe.targetSubresourceType) {
            $drift += "targetSubresourceType (current: '$currentSubresource', desired: '$($mpe.targetSubresourceType)')"
        }
        if ($drift.Count -gt 0) {
            Write-Warning "    MPE '$mpeName' config drift detected: $($drift -join '; '). MPEs are not patchable - delete and re-run to recreate."
        }
    }
    else {
        # ── 2. Create ──────────────────────────────────────────────────────────
        Write-Host "    Creating MPE: $mpeName"

        $createParams = "targetPrivateLinkResourceId=$($mpe.targetPrivateLinkResourceId)"
        $createParams += ",targetSubresourceType=$($mpe.targetSubresourceType)"
        $createParams += ",autoApprovalEnabled=$($autoApprove.ToString().ToLower())"

        $createResult = Invoke-FabCli -Arguments @('create', $mpeFabPath, '-P', $createParams) -AllowNonZeroExit -MaxRetries 1
        if ($createResult.ExitCode -ne 0) {
            $errText = "$($createResult.Stderr) $($createResult.Output)"
            if ($errText -match 'AlreadyExists|already exists|conflict') {
                Write-Warning "    MPE '$mpeName' already exists (identity may lack read permissions). Continuing."
            }
            else {
                throw "fab create failed for MPE '$mpeName' (exit $($createResult.ExitCode)): $errText"
            }
        }
        else {
            Write-Host "    MPE created: $mpeName"
        }

        # Re-fetch for connectionState
        Start-Sleep -Seconds 5
        $getResult = Invoke-FabCli -Arguments @('get', $mpeFabPath, '-q', $mpeQuery) -AllowNonZeroExit -MaxRetries 2 -JsonOutput
        $current = Get-MpeDetails -RawOutput $getResult.Output

        if ($null -eq $current) {
            Write-Warning "    Post-create 'fab get' returned no parseable object. Raw:"
            Write-Warning "    $($getResult.Output | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)"
        }
        else {
            $provState = Get-MpeProp -Obj $current -Key 'provisioningState'    -Default '(unknown)'
            $connState = Get-MpeProp -Obj $current -Key 'connectionStateStatus' -Default '(unknown)'
            Write-Host "    Post-create state: provisioningState=$provState, connectionState=$connState"
        }
    }

    # ── 3. Auto-approval ──────────────────────────────────────────────────────
    $connStatus = Get-MpeProp -Obj $current -Key 'connectionStateStatus'

    if ($connStatus -eq 'Pending' -and $autoApprove) {
        try {
            Initialize-AzCli
            Approve-ManagedPrivateEndpointConnection `
                -TargetResourceId $mpe.targetPrivateLinkResourceId `
                -WorkspaceId      $wsId `
                -MpeName          $mpeName
        }
        catch {
            Write-Warning "    Auto-approval failed for MPE '$mpeName': $_"
        }
    }
    elseif ($connStatus -eq 'Pending') {
        Write-Host "    connectionState is 'Pending' and autoApprovalEnabled=false. Manual approval required on target resource."
        Write-Host "    Expected connection name on target: $wsId.$mpeName-conn"
    }
    elseif ($null -eq $connStatus) {
        Write-Host "    connectionState: (unknown - see raw output above)"
    }
    else {
        Write-Host "    connectionState: $connStatus"
    }

    $processedCount++
}

Write-Host ""
Write-Host "  Managed Private Endpoint deployment complete. Processed: $processedCount."