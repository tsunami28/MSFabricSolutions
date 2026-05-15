#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently deploys VNet Data Gateways for Microsoft Fabric.

.DESCRIPTION
    For each gateway defined in the top-level 'gateways' config block:
      - Checks if the gateway already exists via 'fab exists'
      - Creates missing gateways via 'fab create .gateways/<name>.Gateway'
      - Updates existing gateways whose settings differ via 'fab api PATCH'
      - Configures role assignments via 'fab api' REST endpoints

    All operations are idempotent - safe to re-run without side effects.

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.

.PARAMETER Config
    Validated PSCustomObject from Read-EnvironmentConfig.

.PARAMETER Environment
    Target environment (dev | tst | prd).

.EXAMPLE
    .\Deploy-Gateways.ps1 -Config $config -Environment 'dev'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

# ── Helper: find a gateway by name via the REST API ────────────────────────────
# fab exists / fab get are unreliable for tenant-scoped gateways when the
# identity lacks implicit read access.  The REST API list endpoint works.
function Find-GatewayInApiList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GatewayName)

    $result = Invoke-FabCli -Arguments @(
        'api', 'gateways', '--output_format', 'json'
    ) -AllowNonZeroExit

    if ($result.ExitCode -ne 0 -or -not $result.Output) { return $null }

    $gwList = if ($result.Output -is [array]) { $result.Output }
              elseif ($result.Output.PSObject.Properties.Name -contains 'value') { @($result.Output.value) }
              else { @() }

    return $gwList | Where-Object {
        ($_.PSObject.Properties.Name -contains 'displayName' -and $_.displayName -eq $GatewayName) -or
        ($_.PSObject.Properties.Name -contains 'name'        -and $_.name        -eq $GatewayName)
    } | Select-Object -First 1
}

# ── Check if gateways block exists ─────────────────────────────────────────────
$hasGateways = $Config.PSObject.Properties.Name -contains 'gateways'
if (-not $hasGateways -or $Config.gateways.Count -eq 0) {
    Write-Host "  No gateways defined in config - skipping."
    return
}

$gatewayResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($gwConfig in $Config.gateways) {
    $gwName    = $gwConfig.name
    $gwFabPath = ".gateways/$gwName.Gateway"

    Write-Host "  Processing gateway: $gwName"

    # ── 1. Check existence via REST API ────────────────────────────────────────
    # fab exists / fab get are unreliable for tenant-scoped gateways.
    $gwCurrent = Find-GatewayInApiList -GatewayName $gwName
    $gwId      = if ($gwCurrent -and $gwCurrent.PSObject.Properties.Name -contains 'id') { $gwCurrent.id } else { $null }

    if (-not $gwId) {
        # ── 2. Create gateway ──────────────────────────────────────────────────
        Write-Host "    Creating VNet gateway: $gwName"

        $createParams = "capacity=$($gwConfig.capacityName)"
        $createParams += ",virtualNetworkName=$($gwConfig.virtualNetworkName)"
        $createParams += ",subnetName=$($gwConfig.subnetName)"

        # Optional parameters
        if ($gwConfig.PSObject.Properties.Name -contains 'subscriptionId' -and $gwConfig.subscriptionId) {
            $createParams += ",subscriptionId=$($gwConfig.subscriptionId)"
        }
        if ($gwConfig.PSObject.Properties.Name -contains 'resourceGroupName' -and $gwConfig.resourceGroupName) {
            $createParams += ",resourceGroupName=$($gwConfig.resourceGroupName)"
        }
        if ($gwConfig.PSObject.Properties.Name -contains 'inactivityMinutesBeforeSleep' -and $null -ne $gwConfig.inactivityMinutesBeforeSleep) {
            $createParams += ",inactivityMinutesBeforeSleep=$($gwConfig.inactivityMinutesBeforeSleep)"
        }
        if ($gwConfig.PSObject.Properties.Name -contains 'numberOfMemberGateways' -and $null -ne $gwConfig.numberOfMemberGateways) {
            $createParams += ",numberOfMemberGateways=$($gwConfig.numberOfMemberGateways)"
        }

        $createResult = Invoke-FabCli -Arguments @('create', $gwFabPath, '-P', $createParams) -AllowNonZeroExit
        if ($createResult.ExitCode -ne 0) {
            $errText = "$($createResult.Stderr) $($createResult.Output)"
            if ($errText -match 'AlreadyExists|already exists|name is already in use') {
                throw ("Gateway '$gwName' exists in Fabric but the deployment identity cannot read it via the REST API. " +
                       "Grant the identity a gateway role (e.g. Admin) in the Fabric portal, then re-run the pipeline.")
            }
            Write-Host "##vso[task.logissue type=error]Failed to create VNet gateway '$gwName': $errText"
            Write-Host "    Common causes:"
            Write-Host "      - Subnet '$($gwConfig.subnetName)' not delegated to Microsoft.PowerPlatform/vnetaccesslinks"
            Write-Host "      - Identity lacks Microsoft.Network/virtualNetworks/subnets/join/action on the VNet"
            Write-Host "      - Microsoft.PowerPlatform resource provider not registered in subscription"
            Write-Host "      - Subnet name is reserved (gatewaysubnet, AzureBastionSubnet)"
            throw "fab create failed for gateway '$gwName' (exit $($createResult.ExitCode)): $errText"
        }

        Write-Host "    Gateway created: $gwName"

        # Re-resolve the new gateway's ID from the REST API
        $gwCurrent = Find-GatewayInApiList -GatewayName $gwName
        if ($gwCurrent -and $gwCurrent.PSObject.Properties.Name -contains 'id') {
            $gwId = $gwCurrent.id
        }

        if (-not $gwId) {
            Write-Warning "    Gateway '$gwName' created but ID could not be resolved via REST API. Role assignments will be skipped."
        }

        $gatewayResults.Add([PSCustomObject]@{
            Gateway = $gwName; Action = 'Created'
        })
    } else {
        # ── 3. Update if settings differ ───────────────────────────────────────
        Write-Host "    Gateway exists (id: $gwId). Checking for setting changes..."

        # Build patch body for settings that differ ($gwCurrent from API list)
        $patchBody = @{}

        if ($gwConfig.PSObject.Properties.Name -contains 'inactivityMinutesBeforeSleep' -and
            $null -ne $gwConfig.inactivityMinutesBeforeSleep -and
            $gwCurrent.PSObject.Properties.Name -contains 'inactivityMinutesBeforeSleep' -and
            $gwCurrent.inactivityMinutesBeforeSleep -ne $gwConfig.inactivityMinutesBeforeSleep) {
            $patchBody['inactivityMinutesBeforeSleep'] = $gwConfig.inactivityMinutesBeforeSleep
        }

        if ($gwConfig.PSObject.Properties.Name -contains 'numberOfMemberGateways' -and
            $null -ne $gwConfig.numberOfMemberGateways -and
            $gwCurrent.PSObject.Properties.Name -contains 'numberOfMemberGateways' -and
            $gwCurrent.numberOfMemberGateways -ne $gwConfig.numberOfMemberGateways) {
            $patchBody['numberOfMemberGateways'] = $gwConfig.numberOfMemberGateways
        }

        if ($patchBody.Count -gt 0 -and $gwId) {
            Write-Host "    Updating gateway settings: $($patchBody.Keys -join ', ')"
            $patchJson = $patchBody | ConvertTo-Json -Compress -Depth 5
            Invoke-FabCli -Arguments @('api', '-X', 'patch', "gateways/$gwId", '-i', $patchJson) | Out-Null
            Write-Host "    Gateway updated: $gwName"
            $gatewayResults.Add([PSCustomObject]@{
                Gateway = $gwName; Action = 'Updated'
            })
        } else {
            Write-Verbose "    No setting changes detected for: $gwName"
            $gatewayResults.Add([PSCustomObject]@{
                Gateway = $gwName; Action = 'Skipped'
            })
        }
    }

    # ── 4. Configure role assignments ──────────────────────────────────────────
    $hasRoles = $gwConfig.PSObject.Properties.Name -contains 'roles'
    $roles    = if ($hasRoles) { @($gwConfig.roles | Where-Object { $_ }) } else { @() }

    if ($roles.Count -eq 0) {
        Write-Verbose "    No role assignments defined for gateway: $gwName"
        continue
    }

    if (-not $gwId) {
        Write-Warning "    Cannot resolve gateway ID for '$gwName'. Skipping role assignments."
        continue
    }

    # Get current role assignments
    Write-Host "    Configuring role assignments for gateway: $gwName"
    $currentRolesResult = Invoke-FabCli -Arguments @(
        'api', "gateways/$gwId/roleAssignments", '--output_format', 'json'
    ) -AllowNonZeroExit

    $currentRoles = @()
    if ($currentRolesResult.ExitCode -eq 0 -and $currentRolesResult.Output) {
        $rolesOutput = $currentRolesResult.Output
        # Handle array or wrapped response
        if ($rolesOutput -is [array]) {
            $currentRoles = $rolesOutput
        } elseif ($rolesOutput.PSObject.Properties.Name -contains 'value') {
            $currentRoles = @($rolesOutput.value)
        }
    }

    foreach ($roleConfig in $roles) {
        $identity    = $roleConfig.identity
        $desiredRole = $roleConfig.role
        $shouldRemove = ($roleConfig.PSObject.Properties.Name -contains 'remove') -and ($roleConfig.remove -eq $true)

        # Check if assignment already exists
        $existing = $currentRoles | Where-Object {
            ($_.principal -and $_.principal.id -eq $identity) -or
            ($_.PSObject.Properties.Name -contains 'principalId' -and $_.principalId -eq $identity)
        } | Select-Object -First 1

        if ($shouldRemove) {
            if ($existing) {
                $roleAssignmentId = if ($existing.PSObject.Properties.Name -contains 'id') { $existing.id } else { $null }
                if ($roleAssignmentId) {
                    Write-Host "      Removing $desiredRole for: $identity"
                    Invoke-FabCli -Arguments @(
                        'api', '-X', 'delete', "gateways/$gwId/roleAssignments/$roleAssignmentId"
                    ) | Out-Null
                }
            } else {
                Write-Verbose "      Role not found (already removed): $desiredRole → $identity"
            }
            continue
        }

        $existingRole = if ($existing -and $existing.PSObject.Properties.Name -contains 'role') { $existing.role } else { $null }
        if ($existing -and $existingRole -eq $desiredRole) {
            Write-Verbose "      Assignment exists, no changes: $desiredRole → $identity"
            continue
        }

        # Add new role assignment
        Write-Host "      Assigning $desiredRole to: $identity"
        $assignBody = @{
            principal = @{ id = $identity; type = 'Group' }
            role      = $desiredRole
        } | ConvertTo-Json -Compress -Depth 5
        Invoke-FabCli -Arguments @(
            'api', '-X', 'post', "gateways/$gwId/roleAssignments", '-i', $assignBody
        ) | Out-Null
    }
}

Write-Host "  Gateway deployment complete. Processed: $($gatewayResults.Count) gateway(s)."
return $gatewayResults
