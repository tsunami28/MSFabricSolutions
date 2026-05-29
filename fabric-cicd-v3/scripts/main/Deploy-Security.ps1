#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently configures RBAC role assignments for Fabric workspaces.

.DESCRIPTION
    For each workspace in the config that has a 'roles' block:
      - Retrieves current ACLs via 'fab acl get'
      - Compares against desired state from config
      - Adds missing assignments via 'fab acl set'
      - Removes assignments marked 'remove: true' via 'fab acl rm'
      - Skips assignments that already match

    Assignments are additive by default - roles present in Fabric but absent
    from config are NOT removed (unless explicitly marked 'remove: true').

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.

.NOTES
    Dot-sourced by Deploy-FabricEnvironment.ps1. Not a standalone script.

    'fab acl set' requires the identity's Entra Object ID (GUID).
    Use principalType (Group | User | ServicePrincipal) for documentation
    only - fab acl works with object IDs regardless of type.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,   # workspace name → GUID (from Deploy-Workspaces)

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

$assignmentResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    $hasRoles = $workspaceConfig.PSObject.Properties.Name -contains 'roles'
    $roles = if ($hasRoles) { @($workspaceConfig.roles | Where-Object { $_ }) } else { @() }
    if ($roles.Count -eq 0) {
        Write-Verbose "  No role assignments defined for: $wsName"
        continue
    }

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  Workspace '$wsName' not found in workspace map. Skipping security step."
        continue
    }

    Write-Host "  Configuring roles for workspace: $wsName"

    $wsFabPath = "$wsName.Workspace"

    # ── Get current ACLs ───────────────────────────────────────────────────────
    # Use a JMESPath projection to return rows of { principal, role } objects.
    $aclResult      = Invoke-FabCli -Arguments @(
        'acl', 'get', $wsFabPath,
        '-q', '[].{principal: principal, role: role}'
    ) -JsonOutput
    $rawOutput = $aclResult.Output
    if ($rawOutput -and $rawOutput.PSObject.Properties.Name -contains 'result' -and $rawOutput.result -and $rawOutput.result.PSObject.Properties.Name -contains 'data') {
        $currentAcls = @($rawOutput.result.data)
    } elseif ($rawOutput -is [System.Array]) {
        $currentAcls = @($rawOutput)
    } elseif ($rawOutput -is [System.Collections.Hashtable] -or $rawOutput -is [PSCustomObject]) {
        $currentAcls = @($rawOutput)
    } else {
        $currentAcls = @()
    }

    foreach ($roleConfig in $roles) {
        $identity      = $roleConfig.identity
        $desiredRole   = $roleConfig.role
        $shouldRemove  = ($roleConfig.PSObject.Properties.Name -contains 'remove') -and ($roleConfig.remove -eq $true)

        # Find if this identity already has an assignment
        $existing = $currentAcls | Where-Object {
            $acl = $_
            if ($acl -and $acl.PSObject.Properties.Name -contains 'principal') {
                $p = $acl.principal
                if ($p -is [PSCustomObject] -and $p.PSObject.Properties.Name -contains 'id') {
                    return $p.id -eq $identity
                }
                elseif ($p -is [string]) {
                    return $p -eq $identity
                }
            }
            if ($acl -and $acl.PSObject.Properties.Name -contains 'identity') {
                return $acl.identity -eq $identity
            }
            if ($acl -and $acl.PSObject.Properties.Name -contains 'id') {
                return $acl.id -eq $identity
            }
            $false
        } | Select-Object -First 1

        $existingRole = if ($existing) {
            if ($existing.PSObject.Properties.Name -contains 'role') { $existing.role }
            elseif ($existing.PSObject.Properties.Name -contains 'acl') { $existing.acl }
            else { $null }
        } else { $null }

        Write-Host " Identity $identity has existing assignment: $($existingRole ?? 'None')"

        if ($shouldRemove) {
            if ($existing) {
                Write-Host "    Removing $desiredRole for: $identity"
                Invoke-FabCli -Arguments @('acl', 'rm', $wsFabPath, '-I', $identity, '-f') | Out-Null
                $assignmentResults.Add([PSCustomObject]@{
                    Workspace = $wsName; Identity = $identity; Role = $desiredRole; Action = 'Removed'
                })
            } else {
                Write-Verbose "    Role not found (already removed): $desiredRole → $identity"
                $assignmentResults.Add([PSCustomObject]@{
                    Workspace = $wsName; Identity = $identity; Role = $desiredRole; Action = 'AlreadyAbsent'
                })
            }
            continue
        }

        if ($existing -and $existingRole -eq $desiredRole) {
            Write-Verbose "    Assignment exists, no changes: $desiredRole → $identity"
            $assignmentResults.Add([PSCustomObject]@{
                Workspace = $wsName; Identity = $identity; Role = $desiredRole; Action = 'Skipped'
            })
            continue
        }

        # Assign (or reassign if role changed)
        if ($existing) {
            Write-Host "    Updating role $existingRole → $desiredRole for: $identity"
        } else {
            Write-Host "    Assigning $desiredRole to: $identity"
        }

        Invoke-FabCli -Arguments @('acl', 'set', $wsFabPath, '-I', $identity, '-R', $desiredRole.ToLower(), '-f') | Out-Null
        $assignmentResults.Add([PSCustomObject]@{
            Workspace = $wsName; Identity = $identity; Role = $desiredRole; Action = 'Assigned'
        })
    }
}

Write-Host "  Security deployment complete. Processed: $($assignmentResults.Count) assignment(s)."
return $assignmentResults
