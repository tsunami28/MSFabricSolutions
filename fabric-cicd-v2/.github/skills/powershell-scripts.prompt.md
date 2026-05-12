---
description: "Create or modify PowerShell deployment scripts for fabric-cicd-v2. Use when adding new deployment phases, helpers, or modifying existing scripts."
---

# PowerShell Script Development

## Script Template

All scripts in this project follow this pattern:

```powershell
#Requires -Version 7.0

<#
.SYNOPSIS
    Brief one-line description.

.DESCRIPTION
    Detailed description of what the script does.

.PARAMETER ParamName
    Description of parameter.

.EXAMPLE
    Example invocation.

.NOTES
    Dot-sourced by Deploy-FabricEnvironment.ps1. Not a standalone script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source helpers
$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')
```

## Key Patterns

### Calling Fabric CLI

```powershell
# Standard call (throws on error, retries transient failures)
$result = Invoke-FabCli -Arguments @('ls', 'MyWorkspace.Workspace', '--output_format', 'json')

# Existence check (non-zero exit is expected)
$result = Invoke-FabCli -Arguments @('exists', "$wsName.Workspace") -AllowNonZeroExit
$exists = $result.ExitCode -eq 0

# Create with properties
Invoke-FabCli -Arguments @('mkdir', "$wsName.Workspace", '-P', "capacityname=$capacityName")
```

### Reading Config

```powershell
. (Join-Path $helpersRoot 'Read-EnvironmentConfig.ps1')
$config = Read-EnvironmentConfig -ConfigPath $ConfigFile
```

### Iterating Workspaces

```powershell
foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name
    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "Workspace '$wsName' not in map. Skipping."
        continue
    }
    $wsId = $WorkspaceMap[$wsName]
    # ... do work
}
```

### Checking Optional Config Fields

```powershell
$hasField = $workspaceConfig.PSObject.Properties.Name -contains 'fieldName'
$fieldValue = if ($hasField) { $workspaceConfig.fieldName } else { $null }
```

## Integration with Deploy-FabricEnvironment.ps1

New deployment phases must be:
1. Created as `src/scripts/Deploy-{PhaseName}.ps1`
2. Dot-sourced or called from `Deploy-FabricEnvironment.ps1`
3. Added to the `-Scope` ValidateSet if they should be independently callable
4. Added to `Validate-Deployment.ps1` for post-deployment checks

## Error Handling

- Let errors propagate via `$ErrorActionPreference = 'Stop'`
- Use `try/catch` only when you need specific recovery logic
- Use `Write-Warning` for non-fatal skippable issues
- Never swallow exceptions silently
- Auth errors (exit code 2) are never retried

## Testing Locally

```powershell
# Authenticate first
fab auth login --client-id $clientId --client-secret $secret --tenant-id $tenantId

# Run the orchestrator
.\src\scripts\Deploy-FabricEnvironment.ps1 `
    -ConfigFile 'config/environments/dev.yml' `
    -Environment 'dev' `
    -ClientId $clientId `
    -ClientSecret $secret `
    -TenantId $tenantId `
    -Scope 'workspaces'
```
