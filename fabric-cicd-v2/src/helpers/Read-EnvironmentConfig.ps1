#Requires -Version 7.0

<#
.SYNOPSIS
    Reads and validates a fabric-cicd-v2 environment YAML configuration.

.DESCRIPTION
    Loads the YAML environment config, validates required fields, and returns
    a structured PSCustomObject. Provides clear error messages on missing or
    invalid fields.

    Accepts either:
      - A path to a single monolithic YAML file  (legacy, backward-compatible).
      - A path to a split-file directory         (e.g. config/environments/dev/).

    Required fields:
      environment   - dev | tst | prd
      capacityName  - default Fabric capacity name for workspace creation
      workspaces    - array with at least one workspace definition

    Requires the 'powershell-yaml' module (Install-Module powershell-yaml).

.NOTES
    Dot-sourced by deployment scripts. Not a standalone script.
#>

# =============================================================================
function Merge-EnvironmentConfig {
<#
.SYNOPSIS
    Assembles a merged environment config hashtable from a split-file directory.

.DESCRIPTION
    Loads, in order:
      1. config/shared/defaults.yml          — shared privateLinks base values (optional)
      2. config/shared/roles-common.yml      — RBAC identities injected into every workspace (optional)
      3. <ConfigDir>/_env.yml                — environment-level settings (required)
      4. <ConfigDir>/*.yml (excl. _env.yml)  — one file per workspace, sorted alphabetically

    Merge rules:
      - privateLinks   : defaults.yml fields merged with _env.yml; _env.yml wins on conflict.
      - gateways       : taken from _env.yml only.
      - workspace roles: roles-common.yml entries prepended; duplicates (identity+role) removed.
      - skipCommonRoles: set true on a workspace to opt out of common-role injection.

.PARAMETER ConfigDir
    Path to the environment directory (e.g. config/environments/dev/).

.OUTPUTS
    [hashtable] merged environment config — same shape as a parsed monolithic YAML file.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigDir
    )

    # Normalize: remove trailing path separators so Split-Path works consistently
    $dirPath = $ConfigDir.TrimEnd([char]'/', [char]'\')

    # Locate config/shared/ — two levels above the env directory:
    #   config/environments/dev  → config/environments → config → config/shared
    $envParent  = Split-Path $dirPath   -Parent   # config/environments
    $configRoot = Split-Path $envParent -Parent   # config
    $sharedDir  = Join-Path  $configRoot 'shared' # config/shared

    # ── 1. Load shared defaults (optional) ───────────────────────────────────
    $defaults = @{}
    $defaultsFile = Join-Path $sharedDir 'defaults.yml'
    if (Test-Path $defaultsFile -PathType Leaf) {
        try { $defaults = Get-Content $defaultsFile -Raw | ConvertFrom-Yaml }
        catch { throw "Failed to parse '$defaultsFile': $_" }
        if ($null -eq $defaults) { $defaults = @{} }
    }

    # ── 2. Load common roles (optional) ──────────────────────────────────────
    $commonRoles = @()
    $commonRolesFile = Join-Path $sharedDir 'roles-common.yml'
    if (Test-Path $commonRolesFile -PathType Leaf) {
        try { $rc = Get-Content $commonRolesFile -Raw | ConvertFrom-Yaml }
        catch { throw "Failed to parse '$commonRolesFile': $_" }
        if ($rc -and $rc['roles']) { $commonRoles = @($rc['roles']) }
    }

    # ── 3. Load _env.yml (required) ──────────────────────────────────────────
    $envFile = Join-Path $dirPath '_env.yml'
    if (-not (Test-Path $envFile -PathType Leaf)) {
        throw "Missing required '_env.yml' in '$dirPath'."
    }
    try { $envConfig = Get-Content $envFile -Raw | ConvertFrom-Yaml }
    catch { throw "Failed to parse '$envFile': $_" }
    if ($null -eq $envConfig) { $envConfig = @{} }

    # ── 4. Merge privateLinks: defaults.yml base ← _env.yml overrides ────────
    $mergedPL = @{}
    if ($defaults['privateLinks']) {
        $defaults['privateLinks'].GetEnumerator() | ForEach-Object { $mergedPL[$_.Key] = $_.Value }
    }
    if ($envConfig['privateLinks']) {
        $envConfig['privateLinks'].GetEnumerator() | ForEach-Object { $mergedPL[$_.Key] = $_.Value }
    }
    if ($mergedPL.Count -gt 0) { $envConfig['privateLinks'] = $mergedPL }

    # ── 5. Load workspace files, sorted alphabetically ────────────────────────
    $wsFiles = Get-ChildItem -Path $dirPath -Filter '*.yml' |
               Where-Object { $_.Name -ne '_env.yml' } |
               Sort-Object Name

    $workspaces = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $wsFiles) {
        try { $ws = Get-Content $f.FullName -Raw | ConvertFrom-Yaml }
        catch { throw "Failed to parse workspace file '$($f.FullName)': $_" }
        if ($null -eq $ws) { continue }

        # Merge common roles: prepend common entries not already present (same identity+role)
        if ($commonRoles.Count -gt 0) {
            $skipCommon = $ws.ContainsKey('skipCommonRoles') -and $ws['skipCommonRoles'] -eq $true
            if (-not $skipCommon) {
                $wsRoles     = if ($ws['roles']) { @($ws['roles']) } else { @() }
                $existingIds = $wsRoles | ForEach-Object { "$($_.identity)|$($_.role)" }
                $toPrepend   = @($commonRoles | Where-Object { "$($_.identity)|$($_.role)" -notin $existingIds })
                $ws['roles'] = $toPrepend + $wsRoles
            }
            if ($ws.ContainsKey('skipCommonRoles')) { $ws.Remove('skipCommonRoles') }
        }

        $workspaces.Add($ws)
    }

    $envConfig['workspaces'] = $workspaces.ToArray()
    return $envConfig
}

# =============================================================================
function Read-EnvironmentConfig {
    <#
.SYNOPSIS
    Parses and validates the environment config.

.PARAMETER ConfigPath
    Path to the environment YAML file (e.g. config/environments/dev.yml) or
    directory (e.g. config/environments/dev/) for split-file configs.

.OUTPUTS
    [PSCustomObject] representing the validated environment config.

.EXAMPLE
    $config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev.yml'
    $config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev/'
    $config.environment     # 'dev'
    $config.workspaces[0]   # first workspace definition
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ }, ErrorMessage = "Config path not found: {0}")]
        [string]$ConfigPath
    )

    # ── Ensure powershell-yaml is available ────────────────────────────────────
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue)) {
        throw "Required module 'powershell-yaml' is not installed. Run: Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop

    # ── Load config: directory (split-file), parameters directory, or single monolithic file ─
    if (Test-Path $ConfigPath -PathType Container) {
        # Legacy split-file layout uses '_env.yml'
        $envFileLegacy = Join-Path $ConfigPath '_env.yml'
        if (Test-Path $envFileLegacy -PathType Leaf) {
            $config = Merge-EnvironmentConfig -ConfigDir $ConfigPath
        }
        else {
            # Parameters-style layout: expect an environment file (e.g. dev.yml) plus
            # one YAML per workspace in the same folder. Detect by finding a YAML
            # file in the directory containing a top-level 'environment' key.
            $yamlFiles = Get-ChildItem -Path $ConfigPath -Filter '*.yml' -File
            $foundEnvFile = $null
            $envConfig = $null
            foreach ($f in $yamlFiles) {
                try {
                    $candidate = Get-Content $f.FullName -Raw | ConvertFrom-Yaml
                } catch { continue }
                if ($null -ne $candidate -and $candidate.ContainsKey('environment')) {
                    $foundEnvFile = $f
                    $envConfig = $candidate
                    break
                }
            }

            if ($foundEnvFile) {
                # Load remaining files as per-workspace definitions
                $workspaces = [System.Collections.Generic.List[object]]::new()
                foreach ($f in $yamlFiles) {
                    if ($f.FullName -eq $foundEnvFile.FullName) { continue }
                    try { $ws = Get-Content $f.FullName -Raw | ConvertFrom-Yaml }
                    catch { throw "Failed to parse workspace file '$($f.FullName)': $_" }
                    if ($null -eq $ws) { continue }

                    # Ensure workspace entries have expected shape: either a mapping
                    # representing a single workspace, or an array of workspaces.
                    if ($ws -is [System.Collections.IEnumerable] -and -not ($ws -is [string])) {
                        # If the file declares 'workspaces' at top-level, append them
                        if ($ws.ContainsKey('workspaces')) { $workspaces.AddRange(@($ws['workspaces'])) ; continue }
                        # Otherwise assume the file itself is a single workspace mapping
                        $workspaces.Add($ws) ; continue
                    }
                    else {
                        $workspaces.Add($ws)
                    }
                }

                $envConfig['workspaces'] = $workspaces.ToArray()
                $config = $envConfig
            }
            else {
                throw "Directory '$ConfigPath' does not contain a recognized environment config (_env.yml or a parameters-style env file)."
            }
        }
    } else {
        # Single-file code path (legacy / backward-compatible)
        $raw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        try {
            $config = $raw | ConvertFrom-Yaml -ErrorAction Stop
        } catch {
            throw "Failed to parse YAML config '$ConfigPath': $_"
        }
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
            $git = $ws['gitIntegration']
            $gitLoc = "$loc.gitIntegration"

            # Explicit false = disconnect; nothing further to validate
            if ($git -isnot [System.Collections.IDictionary]) {
                if ($git -ne $false) {
                    throw "Invalid value for $gitLoc in '$ConfigPath'. Must be a mapping or 'false'."
                }
            }
            else {
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
                }
                elseif ($git['provider'] -eq 'GitHub') {
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

            # ── Validate logAnalytics block (if present) ───────────────────────────────
            if ($config.ContainsKey('logAnalytics') -and $null -ne $config['logAnalytics']) {
                $law = $config['logAnalytics']
                $lawLoc = 'logAnalytics'

                foreach ($field in @('subscriptionId', 'resourceGroupName', 'workspaceName')) {
                    if (-not $law.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$law[$field])) {
                        throw "$lawLoc.$field is required when 'logAnalytics' block is present in '$ConfigPath'."
                    }
                }
            }

            # ── Validate per-workspace logAnalytics settings ───────────────────────────
            $wsIdx = 0
            foreach ($ws in $config['workspaces']) {
                if ($ws.ContainsKey('logAnalytics') -and $null -ne $ws['logAnalytics']) {
                    $wsLawVal = $ws['logAnalytics']
                    if ($wsLawVal -isnot [bool]) {
                        throw "workspaces[$wsIdx].logAnalytics must be 'true' or 'false' in '$ConfigPath'. Got: '$wsLawVal'"
                    }
                    if ($wsLawVal -eq $true -and (-not $config.ContainsKey('logAnalytics') -or $null -eq $config['logAnalytics'])) {
                        throw "workspaces[$wsIdx].logAnalytics is 'true' but no top-level 'logAnalytics' block is defined in '$ConfigPath'."
                    }
                }
                $wsIdx++
            }
        }
    }

    # ── Convert to PSCustomObject for consistent property access ───────────────
    $configJson = $config | ConvertTo-Json -Depth 20
    return $configJson | ConvertFrom-Json -Depth 20
}
