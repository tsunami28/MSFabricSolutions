#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently deploys VNet Data Gateways for Microsoft Fabric.

.DESCRIPTION
    For each gateway defined in the top-level 'gateways' config block:
      - Checks if the gateway already exists via 'fab exists'
      - Creates missing gateways via 'fab create .gateways/<name>.Gateway'
      - Updates existing gateways whose settings differ via 'fab api PATCH'
      - Configures role assignments via 'fab acl set' on the gateway path

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

    # ── 1. Check existence ─────────────────────────────────────────────────────
    $allDeployedGateways = fab ls .gateways

    if ($allDeployedGateways -match $gwName) {
        Write-Host "    Gateway '$gwName' found in deployed gateways list."
        $exists = $true
    } else {
        Write-Host "    Gateway '$gwName' NOT found in deployed gateways list."
        $exists = $false
    }

    #$exists = Test-FabResourceExists -Path $gwFabPath

    Write-Host "    Existence check: $($exists ? 'Found' : 'Not found')"

    if (-not $exists) {
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
            if ($errText -match 'AlreadyExists|already exists|name is already in use|conflict') {
                Write-Warning "    Gateway '$gwName' already exists (identity may lack read permissions). Continuing."
                $exists = $true
            } else {
                Write-Host "##vso[task.logissue type=error]Failed to create VNet gateway '$gwName': $errText"
                Write-Host "    Common causes:"
                Write-Host "      - Subnet '$($gwConfig.subnetName)' not delegated to Microsoft.PowerPlatform/vnetaccesslinks"
                Write-Host "      - Identity lacks Microsoft.Network/virtualNetworks/subnets/join/action on the VNet"
                Write-Host "      - Microsoft.PowerPlatform resource provider not registered in subscription"
                Write-Host "      - Subnet name is reserved (gatewaysubnet, AzureBastionSubnet)"
                throw "fab create failed for gateway '$gwName' (exit $($createResult.ExitCode)): $errText"
            }
        } else {
            Write-Host "    Gateway created: $gwName"
            $gatewayResults.Add([PSCustomObject]@{
                Gateway = $gwName; Action = 'Created'
            })
        }
    }

    if ($exists) {
        # ── 3. Update if settings differ ───────────────────────────────────────
        Write-Host "    Gateway exists: $gwName. Checking for setting changes..."

        $gwCurrent = (Invoke-FabCli -Arguments @('get', $gwFabPath) -JsonOutput).Output

        # Build patch body for settings that differ
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

        if ($patchBody.Count -gt 0) {
            $gwId = (Invoke-FabCli -Arguments @('get', $gwFabPath, '-q', 'id')).Output.Trim()
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

    # ── 4. Configure role assignments via fab acl ──────────────────────────────
    $hasRoles = $gwConfig.PSObject.Properties.Name -contains 'roles'
    $roles    = if ($hasRoles) { @($gwConfig.roles | Where-Object { $_ }) } else { @() }

    if ($roles.Count -eq 0) {
        Write-Verbose "    No role assignments defined for gateway: $gwName"
        continue
    }

    Write-Host "    Configuring role assignments for gateway: $gwName"

    # Get current ACL via fab acl get (uses gateway path, no ID needed)
    $currentAclResult = Invoke-FabCli -Arguments @(
        'acl', 'get', $gwFabPath
    ) -AllowNonZeroExit -JsonOutput

    $currentRoles = @()
    if ($currentAclResult.ExitCode -eq 0 -and $currentAclResult.Output) {
        $currentRoles = if ($currentAclResult.Output -is [array]) { $currentAclResult.Output }
                        elseif ($currentAclResult.Output.PSObject.Properties.Name -contains 'value') { @($currentAclResult.Output.value) }
                        else { @($currentAclResult.Output) }
    }

    foreach ($roleConfig in $roles) {
        $identity    = $roleConfig.identity
        $desiredRole = $roleConfig.role
        $shouldRemove = ($roleConfig.PSObject.Properties.Name -contains 'remove') -and ($roleConfig.remove -eq $true)

        # Check if assignment already exists
        $existing = $currentRoles | Where-Object {
            ($_.PSObject.Properties.Name -contains 'principal' -and $_.principal.id -eq $identity) -or
            ($_.PSObject.Properties.Name -contains 'principalId' -and $_.principalId -eq $identity)
        } | Select-Object -First 1

        if ($shouldRemove) {
            if ($existing) {
                Write-Host "      Removing $desiredRole for: $identity"
                Invoke-FabCli -Arguments @('acl', 'rm', $gwFabPath, '-I', $identity, '-f') | Out-Null
            } else {
                Write-Verbose "      Role not found (already removed): $desiredRole -> $identity"
            }
            continue
        }

        $existingRole = if ($existing -and $existing.PSObject.Properties.Name -contains 'role') { $existing.role } else { $null }
        if ($existing -and $existingRole -eq $desiredRole) {
            Write-Verbose "      Assignment exists, no changes: $desiredRole -> $identity"
            continue
        }

        Write-Host "      Assigning $desiredRole to: $identity"
        Invoke-FabCli -Arguments @('acl', 'set', $gwFabPath, '-I', $identity, '-R', $desiredRole, '-f') | Out-Null
    }
}

Write-Host "  Gateway deployment complete. Processed: $($gatewayResults.Count) gateway(s)."
return $gatewayResults
