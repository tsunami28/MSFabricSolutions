#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }
#Requires -Modules @{ ModuleName = 'PSFramework'; ModuleVersion = '1.12.0' }

<#
.SYNOPSIS
    Idempotently deploys Fabric connections defined in the environment parameter file.

.DESCRIPTION
    For each workspace in the config, creates Fabric connections that are referenced
    by external shortcuts (adlsGen2, s3, etc.). Connection creation is idempotent:
    if a connection with the same display name already exists it is left untouched
    (credentials are NOT updated).

    After creation the connection is shared with the target workspace by posting a
    role assignment (POST /v1/connections/{id}/roleAssignments). Connection sharing
    is best-effort — a failure logs a warning but does not fail the deployment.

    Supported connection types  : AzureDataLakeStorage | AzureSqlDatabase | AzureSynapse
    Supported auth methods      : ServicePrincipal | ManagedIdentity

.PARAMETER Config
    Parsed environment configuration (PSCustomObject from the JSON parameter file).

.PARAMETER CapacityMap
    Capacity name-to-ID map. Not used here; present for a consistent step signature.

.PARAMETER Environment
    Target environment name. Valid values: dev | tst | prd.

.PARAMETER DryRun
    When $true, logs planned changes without making any API calls.

.OUTPUTS
    [hashtable]  connection display name → connection ID.
    Returned to Deploy-FabricEnvironment.ps1 and forwarded to Deploy-Items.ps1 so
    that external shortcuts can resolve their connectionRef to a Fabric connection ID.

.NOTES
    Phase 3. Called by Deploy-FabricEnvironment.ps1 via splatting.
    Credential values (clientSecretRef) must already be expanded to real values by the
    ADO pipeline before this script is called — they are supplied as plain variable
    expansions and are never stored in the parameter file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$CapacityMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter()]
    [bool]$DryRun = $false,

    [Parameter()]
    [string[]]$WorkspaceFilter = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load REST helper if not already in scope (normally dot-sourced by the orchestrator)
if (-not (Get-Command -Name 'Invoke-FabricRestMethod' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../helpers/Invoke-FabricRestMethod.ps1')
}

# ── Private helper: build POST /v1/connections request body ───────────────────
function Build-FabricConnectionBody {
    param([PSCustomObject]$Conn)

    # connectionDetails.parameters differ by connection type
    $connParams = switch ($Conn.type) {
        'AzureDataLakeStorage' {
            @( @{ name = 'url'; dataType = 'Text'; value = $Conn.accountUrl } )
        }
        'AzureSqlDatabase' {
            @(
                @{ name = 'server';   dataType = 'Text'; value = $Conn.server   }
                @{ name = 'database'; dataType = 'Text'; value = $Conn.database }
            )
        }
        'AzureSynapse' {
            @(
                @{ name = 'server';   dataType = 'Text'; value = $Conn.server   }
                @{ name = 'database'; dataType = 'Text'; value = $Conn.database }
            )
        }
        default {
            throw "Unsupported connection type '$($Conn.type)'. Supported: AzureDataLakeStorage, AzureSqlDatabase, AzureSynapse."
        }
    }

    # credentialDetails.credentials differ by auth method
    $creds = switch ($Conn.authMethod) {
        'ServicePrincipal' {
            [ordered]@{
                credentialType               = 'ServicePrincipal'
                tenantId                     = $Conn.tenantId
                servicePrincipalClientId     = $Conn.clientId
                servicePrincipalClientSecret = $Conn.clientSecretRef
            }
        }
        'ManagedIdentity' {
            # WorkspaceIdentity = the MI associated with the workspace/capacity
            [ordered]@{ credentialType = 'WorkspaceIdentity' }
        }
        default {
            throw "Unsupported authMethod '$($Conn.authMethod)'. Supported: ServicePrincipal, ManagedIdentity."
        }
    }

    $body = [ordered]@{
        connectivityType  = 'ShareableCloud'
        displayName       = $Conn.name
        privacyLevel      = 'Organizational'
        connectionDetails = [ordered]@{
            type       = $Conn.type
            parameters = $connParams
        }
        credentialDetails = [ordered]@{
            singleSignOnType     = 'None'
            connectionEncryption = 'NotEncrypted'
            skipTestConnection   = $false
            credentials          = $creds
        }
    }

    return $body | ConvertTo-Json -Depth 10
}

# ── Main ───────────────────────────────────────────────────────────────────────
# Returned to the orchestrator; forwarded as $ConnectionMap to Deploy-Items.ps1
$connectionMap = @{}

foreach ($workspaceConfig in $Config.workspaces) {
    if (-not $workspaceConfig.connections -or $workspaceConfig.connections.Count -eq 0) {
        continue
    }

    $wsName = $workspaceConfig.name

    if ($WorkspaceFilter.Count -gt 0 -and $wsName -notin $WorkspaceFilter) {
        Write-PSFMessage -Level Verbose -Message "  Skipping connections for workspace '$wsName' (not in change set)"
        continue
    }

    Write-PSFMessage -Level Host -Message "  Processing connections for workspace: $wsName"

    # Resolve workspace ID — needed to share the connection later
    $workspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        Write-PSFMessage -Level Warning -Message "    Workspace '$wsName' not found. Run the workspaces scope first."
        continue
    }

    # List all connections visible to the deployment MI; build a display-name lookup
    $listUri  = New-FabricUri -Path 'connections'
    $allConns = Invoke-FabricRestMethod -Uri $listUri -Method Get
    $byName   = @{}
    if ($allConns.value) {
        foreach ($c in $allConns.value) { $byName[$c.displayName] = $c }
    }

    foreach ($connConfig in @($workspaceConfig.connections | Where-Object { $_ })) {
        $connName = $connConfig.name
        Write-PSFMessage -Level Host -Message "    Connection: $connName  (type: $($connConfig.type), auth: $($connConfig.authMethod))"

        if ($byName.ContainsKey($connName)) {
            # Idempotent — skip update; credentials are not overwritten
            $connId = $byName[$connName].id
            Write-PSFMessage -Level Verbose -Message "    Connection '$connName' already exists (id: $connId) — skipping."
            $connectionMap[$connName] = $connId
        } elseif ($DryRun) {
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Would create connection '$connName'"
            $connectionMap[$connName] = 'DRY-RUN-ID'
            continue
        } else {
            Write-PSFMessage -Level Host -Message "    Creating connection: $connName"
            $body   = Build-FabricConnectionBody -Conn $connConfig
            $result = Invoke-FabricRestMethod -Uri $listUri -Method Post -Body $body
            $connId = $result.id
            $connectionMap[$connName] = $connId
            Write-PSFMessage -Level Host -Message "    Created connection '$connName' (id: $connId)"
        }

        # Share the connection with the workspace so its items can bind to it at runtime.
        # POST /v1/connections/{id}/roleAssignments
        # Ref: https://learn.microsoft.com/rest/api/fabric/core/connections
        if (-not $DryRun) {
            try {
                $roleBody = @{
                    principal = @{ id = $workspace.id; type = 'Workspace' }
                    role      = 'User'
                } | ConvertTo-Json -Depth 5
                $roleUri = New-FabricUri -Path "connections/$connId/roleAssignments"
                Invoke-FabricRestMethod -Uri $roleUri -Method Post -Body $roleBody | Out-Null
                Write-PSFMessage -Level Verbose -Message "    Shared connection '$connName' with workspace '$wsName'"
            } catch {
                # Non-fatal: connection may already be shared, or the endpoint may differ.
                # Admin can verify under Manage connections and gateways in the Fabric portal.
                Write-PSFMessage -Level Warning -Message "    Could not share connection '$connName' with workspace '$wsName': $_"
                Write-PSFMessage -Level Warning -Message "    Verify connection access in the Fabric portal: Settings → Manage connections and gateways → $connName → Manage access."
                Write-Host "##vso[task.logissue type=warning]Connection '$connName' sharing with workspace '$wsName' failed — verify manually in Fabric portal."
            }
        } else {
            Write-PSFMessage -Level Verbose -Message "    [DRY RUN] Would share connection '$connName' with workspace '$wsName'"
        }
    }
}

Write-PSFMessage -Level Host -Message "  Connections step complete. Resolved: $($connectionMap.Count) connection(s)."
return $connectionMap
