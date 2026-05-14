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

        # Validate gitIntegration block if present
        if ($ws.ContainsKey('gitIntegration') -and $null -ne $ws['gitIntegration']) {
            $git    = $ws['gitIntegration']
            $gitLoc = "$loc.gitIntegration"

            # Explicit false = disconnect; nothing further to validate
            if ($git -isnot [System.Collections.IDictionary]) {
                if ($git -ne $false) {
                    throw "Invalid value for $gitLoc in '$ConfigPath'. Must be a mapping or 'false'."
                }
            } else {
                # provider is required
                if (-not $git['provider']) {
                    throw "$gitLoc.provider is required in '$ConfigPath'."
                }
                $validProviders = @('AzureDevOps', 'GitHub')
                if ($git['provider'] -notin $validProviders) {
                    throw "$gitLoc.provider must be one of: $($validProviders -join ', ') in '$ConfigPath'."
                }

                # Common required fields
                foreach ($field in @('repositoryName', 'branchName')) {
                    if (-not $git[$field]) {
                        throw "$gitLoc.$field is required in '$ConfigPath'."
                    }
                }

                # Provider-specific required fields
                if ($git['provider'] -eq 'AzureDevOps') {
                    foreach ($field in @('organizationName', 'projectName')) {
                        if (-not $git[$field]) {
                            throw "$gitLoc.$field is required for AzureDevOps provider in '$ConfigPath'."
                        }
                    }
                } elseif ($git['provider'] -eq 'GitHub') {
                    if (-not $git['ownerName']) {
                        throw "$gitLoc.ownerName is required for GitHub provider in '$ConfigPath'."
                    }
                    if (-not $git['connectionId']) {
                        throw "$gitLoc.connectionId is required for GitHub provider (Automatic credentials not supported for SPN) in '$ConfigPath'."
                    }
                }

                # Optional enum fields
                if ($git['initializationStrategy'] -and
                    $git['initializationStrategy'] -notin @('None', 'PreferRemote', 'PreferWorkspace')) {
                    throw "$gitLoc.initializationStrategy must be one of: None, PreferRemote, PreferWorkspace in '$ConfigPath'."
                }

                if ($git['conflictResolutionPolicy'] -and
                    $git['conflictResolutionPolicy'] -notin @('PreferRemote', 'PreferWorkspace')) {
                    throw "$gitLoc.conflictResolutionPolicy must be one of: PreferRemote, PreferWorkspace in '$ConfigPath'."
                }
            }
        }

        $idx++
    }

    # ── Validate gateways block (if present) ───────────────────────────────────
    if ($config.ContainsKey('gateways') -and $null -ne $config['gateways']) {
        $gwIdx = 0
        $gatewayNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($gw in $config['gateways']) {
            $gwLoc = "gateways[$gwIdx]"

            # Required fields
            foreach ($field in @('name', 'capacityName', 'virtualNetworkName', 'subnetName')) {
                if (-not $gw[$field]) {
                    throw "$gwLoc.$field is required in '$ConfigPath'."
                }
            }

            if (-not $gatewayNames.Add($gw['name'])) {
                throw "Duplicate gateway name '$($gw['name'])' at $gwLoc in '$ConfigPath'."
            }

            # Validate inactivityMinutesBeforeSleep if present
            if ($gw.ContainsKey('inactivityMinutesBeforeSleep') -and $null -ne $gw['inactivityMinutesBeforeSleep']) {
                $validSleep = @(30, 60, 90, 120, 150, 240, 360, 480, 720, 1440)
                if ($gw['inactivityMinutesBeforeSleep'] -notin $validSleep) {
                    throw "$gwLoc.inactivityMinutesBeforeSleep must be one of: $($validSleep -join ', ') in '$ConfigPath'."
                }
            }

            # Validate numberOfMemberGateways if present
            if ($gw.ContainsKey('numberOfMemberGateways') -and $null -ne $gw['numberOfMemberGateways']) {
                $members = [int]$gw['numberOfMemberGateways']
                if ($members -lt 1 -or $members -gt 9) {
                    throw "$gwLoc.numberOfMemberGateways must be between 1 and 9 in '$ConfigPath'."
                }
            }

            # Validate gateway roles if present
            if ($gw.ContainsKey('roles') -and $null -ne $gw['roles']) {
                $gwRoleIdx = 0
                foreach ($role in @($gw['roles'] | Where-Object { $_ })) {
                    $gwRoleLoc = "$gwLoc.roles[$gwRoleIdx]"
                    if (-not $role['identity']) {
                        throw "$gwRoleLoc.identity is required in '$ConfigPath'."
                    }
                    if (-not $role['role']) {
                        throw "$gwRoleLoc.role is required in '$ConfigPath'."
                    }
                    $validGwRoles = @('Admin', 'ConnectionCreator', 'ConnectionCreatorWithResharing')
                    if ($role['role'] -notin $validGwRoles) {
                        throw "Role '$($role['role'])' at $gwRoleLoc in '$ConfigPath' is invalid. Must be: $($validGwRoles -join ' | ')"
                    }
                    $gwRoleIdx++
                }
            }

            $gwIdx++
        }
    }

    # ── Convert to PSCustomObject for consistent property access ───────────────
    $configJson = $config | ConvertTo-Json -Depth 20
    return $configJson | ConvertFrom-Json -Depth 20
}
