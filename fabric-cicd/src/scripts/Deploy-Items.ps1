#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }

<#
.SYNOPSIS
    Idempotently deploys Fabric items defined in the environment parameter file.

.DESCRIPTION
    For each workspace in the config, deploys the following item types in order:
      1. Lakehouses      — storage layer; description updated when changed
      2. Warehouses      — analytics layer; description updated when changed
      3. Environments    — Spark environments; description updated when changed
      4. Notebooks       — description updated when changed; definition upload deferred to Phase 3
      5. Data Pipelines  — description updated when changed; definition upload deferred to Phase 3
      6. Spark Job Defs  — create/update description (Phase 4); definition upload in Deploy-SparkJobDefinitions.ps1
      7. Shortcuts       — OneLake shortcuts implemented (Phase 2); external shortcuts
                           (adlsGen2/s3/s3Compatible/googleCloudStorage) implemented
                           in Phase 3 via ConnectionMap supplied by Deploy-Connections.ps1

    Items are created if missing; existing items have their description updated when
    the parameter file value differs from the live Fabric value.

.NOTES
    Phase 4 complete. Called by Deploy-FabricEnvironment.ps1 via splatting.
    Requires Invoke-FabricRestMethod.ps1 to be in scope (dot-sourced by orchestrator).
    Can also be run standalone — the REST helper is auto-loaded if missing.
    ConnectionMap (connection name → ID) is provided by Deploy-Connections.ps1 and forwarded
    by the orchestrator. External shortcuts fail the deployment if connectionRef is not in the map.
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
    [hashtable]$ConnectionMap = @{},

    [Parameter()]
    [string[]]$WorkspaceFilter = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load REST helper if not already available (normally dot-sourced by the orchestrator)
if (-not (Get-Command -Name 'Invoke-FabricRestMethod' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../helpers/Invoke-FabricRestMethod.ps1')
}

$deployedItems = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    if ($WorkspaceFilter.Count -gt 0 -and $wsName -notin $WorkspaceFilter) {
        Write-PSFMessage -Level Verbose -Message "  Skipping workspace '$wsName' (not in change set)"
        continue
    }

    # Resolve workspace
    $workspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        Write-PSFMessage -Level Warning -Message "  Workspace '$wsName' not found. Run workspaces scope first."
        continue
    }

    Write-PSFMessage -Level Host -Message "  Deploying items to workspace: $wsName ($($workspace.id))"

    $items = $workspaceConfig.items
    if (-not $items) { continue }

    # ── Lakehouses ─────────────────────────────────────────────────────────────
    foreach ($lhConfig in @($items.lakehouses | Where-Object { $_ })) {
        $existing = Get-FabricLakehouse -WorkspaceId $workspace.id -LakehouseName $lhConfig.name -ErrorAction SilentlyContinue

        if ($DryRun) {
            $action = if ($existing) { 'skip (exists)' } else { 'create' }
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Lakehouse '$($lhConfig.name)': $action"
        } elseif (-not $existing) {
            Write-PSFMessage -Level Host -Message "    Creating lakehouse: $($lhConfig.name)"
            $createParams = @{ WorkspaceId = $workspace.id; LakehouseName = $lhConfig.name }
            if ($lhConfig.description) { $createParams['LakehouseDescription'] = $lhConfig.description }
            New-FabricLakehouse @createParams | Out-Null
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Lakehouse'; Name = $lhConfig.name; Action = 'Created' })
        } else {
            $action = 'Skipped'
            if ($lhConfig.description -and $existing.description -ne $lhConfig.description) {
                Write-PSFMessage -Level Host -Message "    Updating lakehouse description: $($lhConfig.name)"
                Update-FabricLakehouse -WorkspaceId $workspace.id -LakehouseId $existing.id -LakehouseDescription $lhConfig.description | Out-Null
                $action = 'Updated'
            } else {
                Write-PSFMessage -Level Verbose -Message "    Lakehouse exists, no changes: $($lhConfig.name)"
            }
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Lakehouse'; Name = $lhConfig.name; Action = $action })
        }
    }

    # ── Warehouses ─────────────────────────────────────────────────────────────
    foreach ($whConfig in @($items.warehouses | Where-Object { $_ })) {
        $existing = Get-FabricWarehouse -WorkspaceId $workspace.id -WarehouseName $whConfig.name -ErrorAction SilentlyContinue

        if ($DryRun) {
            $action = if ($existing) { 'skip (exists)' } else { 'create' }
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Warehouse '$($whConfig.name)': $action"
        } elseif (-not $existing) {
            Write-PSFMessage -Level Host -Message "    Creating warehouse: $($whConfig.name)"
            $createParams = @{ WorkspaceId = $workspace.id; WarehouseName = $whConfig.name }
            if ($whConfig.description) { $createParams['WarehouseDescription'] = $whConfig.description }
            New-FabricWarehouse @createParams | Out-Null
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Warehouse'; Name = $whConfig.name; Action = 'Created' })
        } else {
            $action = 'Skipped'
            if ($whConfig.description -and $existing.description -ne $whConfig.description) {
                Write-PSFMessage -Level Host -Message "    Updating warehouse description: $($whConfig.name)"
                Update-FabricWarehouse -WorkspaceId $workspace.id -WarehouseId $existing.id -WarehouseDescription $whConfig.description | Out-Null
                $action = 'Updated'
            } else {
                Write-PSFMessage -Level Verbose -Message "    Warehouse exists, no changes: $($whConfig.name)"
            }
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Warehouse'; Name = $whConfig.name; Action = $action })
        }
    }

    # ── Spark Environments ─────────────────────────────────────────────────────
    foreach ($envConfig in @($items.environments | Where-Object { $_ })) {
        $existing = Get-FabricEnvironment -WorkspaceId $workspace.id -EnvironmentName $envConfig.name -ErrorAction SilentlyContinue

        if ($DryRun) {
            $action = if ($existing) { 'skip (exists)' } else { 'create' }
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Environment '$($envConfig.name)': $action"
        } elseif (-not $existing) {
            Write-PSFMessage -Level Host -Message "    Creating environment: $($envConfig.name)"
            $createParams = @{ WorkspaceId = $workspace.id; EnvironmentName = $envConfig.name }
            if ($envConfig.description) { $createParams['EnvironmentDescription'] = $envConfig.description }
            New-FabricEnvironment @createParams | Out-Null
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Environment'; Name = $envConfig.name; Action = 'Created' })
        } else {
            $action = 'Skipped'
            if ($envConfig.description -and $existing.description -ne $envConfig.description) {
                Write-PSFMessage -Level Host -Message "    Updating environment description: $($envConfig.name)"
                Update-FabricEnvironment -WorkspaceId $workspace.id -EnvironmentId $existing.id -EnvironmentDescription $envConfig.description | Out-Null
                $action = 'Updated'
            } else {
                Write-PSFMessage -Level Verbose -Message "    Environment exists, no changes: $($envConfig.name)"
            }
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Environment'; Name = $envConfig.name; Action = $action })
        }
    }

    # ── Notebooks ──────────────────────────────────────────────────────────────
    foreach ($nbConfig in @($items.notebooks | Where-Object { $_ })) {
        $existing = Get-FabricNotebook -WorkspaceId $workspace.id -NotebookName $nbConfig.name -ErrorAction SilentlyContinue

        if ($DryRun) {
            $action = if ($existing) { 'update definition' } else { 'create' }
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Notebook '$($nbConfig.name)': $action"
        } elseif (-not $existing) {
            Write-PSFMessage -Level Host -Message "    Creating notebook: $($nbConfig.name)"
            $createParams = @{ WorkspaceId = $workspace.id; NotebookName = $nbConfig.name }
            if ($nbConfig.description) { $createParams['NotebookDescription'] = $nbConfig.description }
            $newNb = New-FabricNotebook @createParams
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Notebook'; Name = $nbConfig.name; Action = 'Created' })

            # Definition upload deferred to Phase 3
            if ($nbConfig.definitionPath) {
                Write-PSFMessage -Level Verbose -Message "    Notebook definition upload deferred to Phase 3: $($nbConfig.name)"
            }
        } else {
            $action = 'Skipped'
            if ($nbConfig.description -and $existing.description -ne $nbConfig.description) {
                Write-PSFMessage -Level Host -Message "    Updating notebook description: $($nbConfig.name)"
                Update-FabricNotebook -WorkspaceId $workspace.id -NotebookId $existing.id -NotebookDescription $nbConfig.description | Out-Null
                $action = 'Updated'
            } else {
                Write-PSFMessage -Level Verbose -Message "    Notebook exists, no changes: $($nbConfig.name)"
            }
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Notebook'; Name = $nbConfig.name; Action = $action })
        }
    }

    # ── Data Pipelines ─────────────────────────────────────────────────────────
    foreach ($plConfig in @($items.dataPipelines | Where-Object { $_ })) {
        $existing = Get-FabricDataPipeline -WorkspaceId $workspace.id -DataPipelineName $plConfig.name -ErrorAction SilentlyContinue

        if ($DryRun) {
            $action = if ($existing) { 'skip (exists)' } else { 'create' }
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Data Pipeline '$($plConfig.name)': $action"
        } elseif (-not $existing) {
            Write-PSFMessage -Level Host -Message "    Creating data pipeline: $($plConfig.name)"
            $createParams = @{ WorkspaceId = $workspace.id; DataPipelineName = $plConfig.name }
            if ($plConfig.description) { $createParams['DataPipelineDescription'] = $plConfig.description }
            New-FabricDataPipeline @createParams | Out-Null
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'DataPipeline'; Name = $plConfig.name; Action = 'Created' })
        } else {
            $action = 'Skipped'
            if ($plConfig.description -and $existing.description -ne $plConfig.description) {
                Write-PSFMessage -Level Host -Message "    Updating data pipeline description: $($plConfig.name)"
                Update-FabricDataPipeline -WorkspaceId $workspace.id -DataPipelineId $existing.id -DataPipelineDescription $plConfig.description | Out-Null
                $action = 'Updated'
            } else {
                Write-PSFMessage -Level Verbose -Message "    Data pipeline exists, no changes: $($plConfig.name)"
            }
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'DataPipeline'; Name = $plConfig.name; Action = $action })
        }
    }

    # ── Spark Job Definitions ─────────────────────────────────────────────
    foreach ($sjdConfig in @($items.sparkJobDefinitions | Where-Object { $_ })) {
        $existing = Get-FabricSparkJobDefinition -WorkspaceId $workspace.id -SparkJobDefinitionName $sjdConfig.name -ErrorAction SilentlyContinue

        if ($DryRun) {
            $action = if ($existing) { 'skip (exists)' } else { 'create' }
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Spark Job Definition '$($sjdConfig.name)': $action"
        } elseif (-not $existing) {
            Write-PSFMessage -Level Host -Message "    Creating Spark Job Definition: $($sjdConfig.name)"
            $createParams = @{ WorkspaceId = $workspace.id; SparkJobDefinitionName = $sjdConfig.name }
            if ($sjdConfig.description) { $createParams['SparkJobDefinitionDescription'] = $sjdConfig.description }
            New-FabricSparkJobDefinition @createParams | Out-Null
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'SparkJobDefinition'; Name = $sjdConfig.name; Action = 'Created' })
        } else {
            $action = 'Skipped'
            if ($sjdConfig.description -and $existing.description -ne $sjdConfig.description) {
                Write-PSFMessage -Level Host -Message "    Updating Spark Job Definition description: $($sjdConfig.name)"
                Update-FabricSparkJobDefinition -WorkspaceId $workspace.id -SparkJobDefinitionId $existing.id -SparkJobDefinitionDescription $sjdConfig.description | Out-Null
                $action = 'Updated'
            } else {
                Write-PSFMessage -Level Verbose -Message "    Spark Job Definition exists, no changes: $($sjdConfig.name)"
            }
            $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'SparkJobDefinition'; Name = $sjdConfig.name; Action = $action })
        }
    }

    # ── Shortcuts ──────────────────────────────────────────────────────────────
    foreach ($scConfig in @($workspaceConfig.shortcuts | Where-Object { $_ })) {
        $lakehouse = Get-FabricLakehouse -WorkspaceId $workspace.id -LakehouseName $scConfig.lakehouseName -ErrorAction SilentlyContinue
        if (-not $lakehouse) {
            Write-PSFMessage -Level Warning -Message "    Lakehouse '$($scConfig.lakehouseName)' not found for shortcut '$($scConfig.shortcutName)'. Skipping."
            continue
        }

        $targetType = $scConfig.target.type

        if ($targetType -eq 'oneLake') {
            # ── OneLake shortcut (Phase 2) ────────────────────────────────────
            $targetWorkspace = Get-FabricWorkspace -WorkspaceName $scConfig.target.workspaceName -ErrorAction SilentlyContinue
            if (-not $targetWorkspace) {
                Write-PSFMessage -Level Warning -Message "    Shortcut '$($scConfig.shortcutName)': target workspace '$($scConfig.target.workspaceName)' not found. Skipping."
                continue
            }
            $targetItem = Get-FabricLakehouse -WorkspaceId $targetWorkspace.id -LakehouseName $scConfig.target.itemName -ErrorAction SilentlyContinue
            if (-not $targetItem) {
                Write-PSFMessage -Level Warning -Message "    Shortcut '$($scConfig.shortcutName)': target item '$($scConfig.target.itemName)' not found in workspace '$($scConfig.target.workspaceName)'. Skipping."
                continue
            }

            $existingShortcut = Get-FabricOneLakeShortcut -WorkspaceId $workspace.id -ItemId $lakehouse.id -ShortcutName $scConfig.shortcutName -ErrorAction SilentlyContinue

            if ($DryRun) {
                $scAction = if ($existingShortcut) { 'skip (exists)' } else { 'create' }
                Write-PSFMessage -Level Host -Message "    [DRY RUN] OneLake shortcut '$($scConfig.shortcutName)' → $($scConfig.target.workspaceName)/$($scConfig.target.itemName): $scAction"
            } elseif (-not $existingShortcut) {
                Write-PSFMessage -Level Host -Message "    Creating OneLake shortcut: $($scConfig.shortcutName)"
                $mountPath = if ($scConfig.subpath) { $scConfig.subpath } else { 'Files' }
                $body = @{
                    name   = $scConfig.shortcutName
                    path   = $mountPath
                    target = @{
                        oneLake = @{
                            workspaceId = $targetWorkspace.id
                            itemId      = $targetItem.id
                            path        = $scConfig.target.path
                        }
                    }
                } | ConvertTo-Json -Depth 5
                $shortcutUri = New-FabricUri -Path "workspaces/$($workspace.id)/items/$($lakehouse.id)/shortcuts"
                Invoke-FabricRestMethod -Uri $shortcutUri -Method Post -Body $body | Out-Null
                $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Shortcut'; Name = $scConfig.shortcutName; Action = 'Created' })
            } else {
                Write-PSFMessage -Level Verbose -Message "    Shortcut exists, no changes: $($scConfig.shortcutName)"
                $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Shortcut'; Name = $scConfig.shortcutName; Action = 'Skipped' })
            }

        } elseif ($targetType -in @('adlsGen2', 's3', 's3Compatible', 'googleCloudStorage')) {
            # ── External shortcut (Phase 3) ───────────────────────────────────
            # The connection must have been created by Deploy-Connections.ps1 and passed
            # in as ConnectionMap by the orchestrator.
            $connRef = $scConfig.target.connectionRef
            if (-not $connRef) {
                throw "Shortcut '$($scConfig.shortcutName)': 'target.connectionRef' is required for external target type '$targetType'."
            }
            if (-not $ConnectionMap.ContainsKey($connRef)) {
                throw "Shortcut '$($scConfig.shortcutName)': connectionRef '$connRef' was not found in the connection map. Ensure the connection is defined in workspaces[].connections and the 'connections' step ran successfully."
            }

            $connId    = $ConnectionMap[$connRef]
            $mountPath = if ($scConfig.subpath) { $scConfig.subpath } else { 'Files' }

            $existingShortcut = Get-FabricOneLakeShortcut -WorkspaceId $workspace.id -ItemId $lakehouse.id -ShortcutName $scConfig.shortcutName -ErrorAction SilentlyContinue

            if ($DryRun) {
                $scAction = if ($existingShortcut) { 'skip (exists)' } else { 'create' }
                Write-PSFMessage -Level Host -Message "    [DRY RUN] External shortcut '$($scConfig.shortcutName)' ($targetType → $($scConfig.target.url)): $scAction"
            } elseif (-not $existingShortcut) {
                Write-PSFMessage -Level Host -Message "    Creating external shortcut: $($scConfig.shortcutName) ($targetType)"
                # Fabric shortcut API: the target key matches the type name (e.g. adlsGen2 → { adlsGen2: {...} })
                $body = @{
                    name   = $scConfig.shortcutName
                    path   = $mountPath
                    target = @{
                        $targetType = @{
                            location     = $scConfig.target.url
                            subpath      = if ($scConfig.target.subpath) { $scConfig.target.subpath } else { '' }
                            connectionId = $connId
                        }
                    }
                } | ConvertTo-Json -Depth 5
                $shortcutUri = New-FabricUri -Path "workspaces/$($workspace.id)/items/$($lakehouse.id)/shortcuts"
                Invoke-FabricRestMethod -Uri $shortcutUri -Method Post -Body $body | Out-Null
                $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Shortcut'; Name = $scConfig.shortcutName; Action = 'Created' })
            } else {
                Write-PSFMessage -Level Verbose -Message "    External shortcut exists, no changes: $($scConfig.shortcutName)"
                $deployedItems.Add([PSCustomObject]@{ Workspace = $wsName; Type = 'Shortcut'; Name = $scConfig.shortcutName; Action = 'Skipped' })
            }

        } else {
            Write-PSFMessage -Level Warning -Message "    Shortcut '$($scConfig.shortcutName)': unsupported target type '$targetType'. Skipping."
        }
    }
}

Write-PSFMessage -Level Host -Message "  Item deployment complete. Processed: $($deployedItems.Count)"
return $deployedItems
