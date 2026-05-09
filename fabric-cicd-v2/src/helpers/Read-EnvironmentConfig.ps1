#Requires -Version 7.0

<#
.SYNOPSIS
    Reads and validates a fabric-cicd-v2 environment YAML configuration file.

.DESCRIPTION
    Loads the YAML environment config, validates required fields, and returns
    a structured PSCustomObject. Provides clear error messages on missing or
    invalid fields.

    Required fields:
      environment   - dev | tst | prd
      capacityName  - default Fabric capacity name for workspace creation
      workspaces    - array with at least one workspace definition

    Requires the 'powershell-yaml' module (Install-Module powershell-yaml).

.NOTES
    Dot-sourced by deployment scripts. Not a standalone script.
#>

# =============================================================================
function Read-EnvironmentConfig {
<#
.SYNOPSIS
    Parses and validates the environment YAML config file.

.PARAMETER ConfigPath
    Path to the environment YAML file (e.g. config/environments/dev.yml).

.OUTPUTS
    [PSCustomObject] representing the validated environment config.

.EXAMPLE
    $config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev.yml'
    $config.environment     # 'dev'
    $config.workspaces[0]   # first workspace definition
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
        [string]$ConfigPath
    )

    # ── Ensure powershell-yaml is available ────────────────────────────────────
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue)) {
        throw "Required module 'powershell-yaml' is not installed. Run: Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop

    # ── Parse YAML ─────────────────────────────────────────────────────────────
    $raw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
    try {
        $config = $raw | ConvertFrom-Yaml -ErrorAction Stop
    } catch {
        throw "Failed to parse YAML config '$ConfigPath': $_"
    }

    # ── Validate required top-level fields ─────────────────────────────────────
    $missingFields = @()
    foreach ($field in @('environment', 'capacityName', 'workspaces')) {
        if (-not $config.ContainsKey($field) -or $null -eq $config[$field]) {
            $missingFields += $field
        }
    }
    if ($missingFields.Count -gt 0) {
        throw "Environment config '$ConfigPath' is missing required field(s): $($missingFields -join ', ')"
    }

    if ($config['environment'] -notin @('dev', 'tst', 'prd')) {
        throw "Invalid environment '$($config['environment'])' in '$ConfigPath'. Must be: dev | tst | prd"
    }

    if (-not $config['workspaces'] -or $config['workspaces'].Count -eq 0) {
        throw "Environment config '$ConfigPath' must define at least one workspace."
    }

    # ── Validate each workspace ────────────────────────────────────────────────
    $workspaceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $idx = 0
    foreach ($ws in $config['workspaces']) {
        $loc = "workspaces[$idx]"

        if (-not $ws['name']) {
            throw "Workspace at $loc in '$ConfigPath' is missing required field 'name'."
        }
        if (-not $workspaceNames.Add($ws['name'])) {
            throw "Duplicate workspace name '$($ws['name'])' at $loc in '$ConfigPath'."
        }

        # Validate roles if present
        $roleIdx = 0
        foreach ($role in @($ws['roles'] | Where-Object { $_ })) {
            $roleLoc = "$loc.roles[$roleIdx]"
            if (-not $role['identity']) {
                throw "Role at $roleLoc in '$ConfigPath' is missing required field 'identity'."
            }
            if (-not $role['role']) {
                throw "Role at $roleLoc in '$ConfigPath' is missing required field 'role'."
            }
            $validRoles = @('Admin', 'Member', 'Contributor', 'Viewer')
            if ($role['role'] -notin $validRoles) {
                throw "Role '$($role['role'])' at $roleLoc in '$ConfigPath' is invalid. Must be: $($validRoles -join ' | ')"
            }
            if ($role['principalType'] -and $role['principalType'] -notin @('Group', 'User', 'ServicePrincipal')) {
                throw "principalType '$($role['principalType'])' at $roleLoc is invalid. Must be: Group | User | ServicePrincipal"
            }
            $roleIdx++
        }

        $idx++
    }

    # ── Convert to PSCustomObject for consistent property access ───────────────
    $configJson = $config | ConvertTo-Json -Depth 20
    return $configJson | ConvertFrom-Json -Depth 20
}
