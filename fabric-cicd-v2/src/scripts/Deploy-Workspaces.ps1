#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently provisions Fabric workspaces defined in the environment config.

.DESCRIPTION
    For each workspace in the config:
      - Checks if the workspace exists (fab exists)
      - Creates it if missing (fab mkdir) with the configured capacity
      - Updates description if changed (fab set)
      - Returns a hashtable of workspace name → workspace GUID

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.

.NOTES
    Dot-sourced by Deploy-FabricEnvironment.ps1. Not a standalone script.
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

$workspaceMap = @{}  # name → GUID

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName      = $workspaceConfig.name
    $description = $workspaceConfig.description ?? ''
    $capacity    = $workspaceConfig.capacityOverride ?? $Config.capacityName

    Write-Host "  Processing workspace: $wsName"

    # ── Check existence ────────────────────────────────────────────────────────
    $exists = Test-FabResourceExists -Path "$wsName.Workspace"

    if (-not $exists) {
        # ── Create workspace ───────────────────────────────────────────────────
        Write-Host "    Creating workspace: $wsName (capacity: $capacity)"

        # Set the default capacity before creating — more reliable than -P capacityname
        if ($capacity) {
            Invoke-FabCli -Arguments @('config', 'set', 'default_capacity', $capacity) -MaxRetries 0 | Out-Null
        }

        $createArgs = @('mkdir', "$wsName.Workspace")
        if ($description) {
            $createArgs += @('-P', "description=$description")
        }

        $mkdirResult = Invoke-FabCli -Arguments $createArgs -AllowNonZeroExit
        if ($mkdirResult.ExitCode -ne 0) {
            # Workspace may already exist but the identity lacks read access (fab exists returned false)
            $errText = "$($mkdirResult.Stderr) $($mkdirResult.Output)".ToLowerInvariant()
            if ($errText -match 'already exists|name is already in use|conflict') {
                Write-Warning "    Workspace '$wsName' already exists (identity may lack read permissions). Continuing."
                $exists = $true
            } else {
                throw "fab mkdir failed for '$wsName' (exit $($mkdirResult.ExitCode)): $($mkdirResult.Stderr) $($mkdirResult.Output)"
            }
        } else {
            Write-Host "    Created: $wsName"
        }
    }

    if ($exists) {
        # ── Update description if changed ──────────────────────────────────────
        if ($description) {
            Write-Host "    Workspace exists. Updating description if needed: $wsName"
            $setArgs = @('set', "$wsName.Workspace", '-q', 'description', '-i', $description, '-f')
            Invoke-FabCli -Arguments $setArgs -MaxRetries 1 | Out-Null
        } else {
            Write-Host "    Workspace exists, no changes required: $wsName"
        }
    }

    # ── Retrieve workspace GUID ────────────────────────────────────────────────
    $idResult = Invoke-FabCli -Arguments @('get', "$wsName.Workspace", '-q', 'id')

    # 'fab get ... -q id' returns a bare GUID string
    $wsId = $idResult.Output
    if ($wsId -is [string]) {
        $wsId = $wsId.Trim('"').Trim()
    }

    if (-not $wsId) {
        throw "Failed to retrieve workspace ID for '$wsName'. fab get returned empty output."
    }

    $workspaceMap[$wsName] = $wsId
    Write-Host "    Workspace ID: $wsId"
}

Write-Host "  Workspace deployment complete. Processed: $($workspaceMap.Count) workspace(s)."
return $workspaceMap
