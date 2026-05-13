# Workspace Git Integration Plan

## Objective

Automate the connection of Fabric workspaces to Git repositories (Azure DevOps or GitHub) and perform initial synchronization as part of the `fabric-cicd-v2` deployment pipeline using the Fabric CLI (`fab`).

## Overview

Microsoft Fabric supports connecting workspaces to Git repositories, enabling source-controlled development of Fabric items (notebooks, pipelines, semantic models, reports, etc.). Once connected, workspace changes can be committed to Git and remote changes can be pulled into the workspace.

The Git integration lifecycle follows a three-step flow:

1. **Connect** — Link the workspace to a specific repo/branch/directory
2. **Initialize Connection** — Determine which side (workspace or remote) has newer content
3. **Sync** — Either _Update From Git_ (pull remote → workspace) or _Commit To Git_ (push workspace → remote)

This deployment phase automates step 1 and 2, with a configurable strategy for step 3. Step 3 defaults to _Update From Git_ for target environments (tst/prd) and is configurable for dev.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Azure DevOps / GitHub Repository                                       │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐      │
│  │  main             │  │  release/tst     │  │  release/prd     │      │
│  │  ┌──────────────┐ │  │  ┌──────────────┐│  │  ┌──────────────┐│     │
│  │  │ FIN-Core-Dev │ │  │  │ FIN-Core-Tst ││  │  │ FIN-Core-Prd ││     │
│  │  │   .Workspace │ │  │  │   .Workspace ││  │  │   .Workspace ││     │
│  │  └──────────────┘ │  │  └──────────────┘│  │  └──────────────┘│     │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘      │
│           │                      │                      │               │
└───────────┼──────────────────────┼──────────────────────┼───────────────┘
            │ connect + sync       │ connect + sync       │ connect + sync
            ▼                      ▼                      ▼
  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
  │ FIN-Core-Dev     │  │ FIN-Core-Tst     │  │ FIN-Core-Prd     │
  │ (Fabric ws)      │  │ (Fabric ws)      │  │ (Fabric ws)      │
  └──────────────────┘  └──────────────────┘  └──────────────────┘
```

Each workspace connects to its own branch (or the same branch with a different directory). Per-environment branch and directory configuration allows flexible promotion strategies.

## Fabric CLI Support

There are **no dedicated `fab` commands** for Git integration. All operations are done via `fab api` against the Fabric REST API (`https://api.fabric.microsoft.com/v1/`).

## API Details

All endpoints are relative to `https://api.fabric.microsoft.com/v1/`.

| Operation | Method | Endpoint | LRO |
|---|---|---|---|
| Get Git connection | `GET` | `workspaces/{workspaceId}/git/connection` | No |
| Connect to Git | `POST` | `workspaces/{workspaceId}/git/connect` | No |
| Disconnect from Git | `POST` | `workspaces/{workspaceId}/git/disconnect` | No |
| Initialize connection | `POST` | `workspaces/{workspaceId}/git/initializeConnection` | Yes |
| Get Git status | `GET` | `workspaces/{workspaceId}/git/status` | Yes |
| Commit to Git | `POST` | `workspaces/{workspaceId}/git/commitToGit` | Yes |
| Update from Git | `POST` | `workspaces/{workspaceId}/git/updateFromGit` | Yes |
| Get my Git credentials | `GET` | `workspaces/{workspaceId}/git/myGitCredentials` | No |
| Update my Git credentials | `PATCH` | `workspaces/{workspaceId}/git/myGitCredentials` | No |

### Long-Running Operations (LRO)

Several Git API calls (Initialize Connection, Get Status, Commit, Update) support LRO. When the API returns `202 Accepted`, the response contains:

- `Location` header — URL to poll for operation status
- `x-ms-operation-id` header — Operation ID
- `Retry-After` header — Suggested polling interval in seconds

Poll `GET /v1/operations/{operationId}` until the operation completes or fails.

### fab CLI Usage

#### Get current Git connection

```bash
fab api workspaces/<workspaceId>/git/connection --output_format json
```

Response when connected:
```json
{
  "gitProviderDetails": {
    "organizationName": "MyOrg",
    "projectName": "MyProject",
    "gitProviderType": "AzureDevOps",
    "repositoryName": "fabric-items",
    "branchName": "main",
    "directoryName": "FIN-Core-Dev.Workspace"
  },
  "gitSyncDetails": {
    "head": "eaa737b48cda41b37ffefac772ea48f6fed3eac4",
    "lastSyncTime": "2025-11-20T09:26:43.153"
  },
  "gitConnectionState": "ConnectedAndInitialized"
}
```

Response when not connected:
```json
{
  "gitProviderDetails": null,
  "gitSyncDetails": null,
  "gitConnectionState": "NotConnected"
}
```

#### Connect workspace to Azure DevOps

```bash
fab api -X post workspaces/<workspaceId>/git/connect \
  -i '{
    "gitProviderDetails": {
      "gitProviderType": "AzureDevOps",
      "organizationName": "MyOrg",
      "projectName": "MyProject",
      "repositoryName": "fabric-items",
      "branchName": "main",
      "directoryName": "FIN-Core-Dev.Workspace"
    }
  }'
```

#### Connect workspace to Azure DevOps with Configured Connection credentials

```bash
fab api -X post workspaces/<workspaceId>/git/connect \
  -i '{
    "gitProviderDetails": {
      "gitProviderType": "AzureDevOps",
      "organizationName": "MyOrg",
      "projectName": "MyProject",
      "repositoryName": "fabric-items",
      "branchName": "main",
      "directoryName": "FIN-Core-Dev.Workspace"
    },
    "myGitCredentials": {
      "source": "ConfiguredConnection",
      "connectionId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    }
  }'
```

#### Connect workspace to GitHub

```bash
fab api -X post workspaces/<workspaceId>/git/connect \
  -i '{
    "gitProviderDetails": {
      "gitProviderType": "GitHub",
      "ownerName": "my-org",
      "repositoryName": "fabric-items",
      "branchName": "main",
      "directoryName": "FIN-Core-Dev.Workspace"
    },
    "myGitCredentials": {
      "source": "ConfiguredConnection",
      "connectionId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    }
  }'
```

#### Disconnect workspace from Git

```bash
fab api -X post workspaces/<workspaceId>/git/disconnect
```

#### Initialize connection (after connect)

```bash
fab api -X post workspaces/<workspaceId>/git/initializeConnection \
  -i '{"initializationStrategy": "PreferRemote"}'
```

Response:
```json
{
  "requiredAction": "UpdateFromGit",
  "workspaceHead": "eaa737b48cda41b37ffefac772ea48f6fed3eac4",
  "remoteCommitHash": "7d03b2918bf6aa62f96d0a4307293f3853201705"
}
```

`requiredAction` values: `None`, `UpdateFromGit`, `CommitToGit`.

#### Update from Git (pull remote → workspace)

```bash
fab api -X post workspaces/<workspaceId>/git/updateFromGit \
  -i '{
    "workspaceHead": "eaa737b48cda41b37ffefac772ea48f6fed3eac4",
    "remoteCommitHash": "7d03b2918bf6aa62f96d0a4307293f3853201705",
    "conflictResolution": {
      "conflictResolutionType": "Workspace",
      "conflictResolutionPolicy": "PreferRemote"
    },
    "options": {
      "allowOverrideItems": true
    }
  }'
```

#### Commit to Git (push workspace → remote)

```bash
fab api -X post workspaces/<workspaceId>/git/commitToGit \
  -i '{
    "mode": "All",
    "workspaceHead": "eaa737b48cda41b37ffefac772ea48f6fed3eac4",
    "comment": "Automated commit from fabric-cicd-v2"
  }'
```

#### Get status

```bash
fab api workspaces/<workspaceId>/git/status --output_format json
```

Via `Invoke-FabCli` (PowerShell):

```powershell
# Get current connection
$result = Invoke-FabCli -Arguments @(
    'api', "workspaces/$wsId/git/connection",
    '--output_format', 'json'
)
$connection = $result.Output | ConvertFrom-Json

# Connect to Azure DevOps
$connectPayload = @{
    gitProviderDetails = @{
        gitProviderType  = 'AzureDevOps'
        organizationName = $git.organizationName
        projectName      = $git.projectName
        repositoryName   = $git.repositoryName
        branchName       = $git.branchName
        directoryName    = $git.directoryName
    }
} | ConvertTo-Json -Depth 5 -Compress

Invoke-FabCli -Arguments @(
    'api', '-X', 'post',
    "workspaces/$wsId/git/connect",
    '-i', $connectPayload
)
```

## Prerequisites

### 1. Fabric capacity requirement

The Fabric workspace must be assigned to a **Fabric capacity (F SKU)** or **Power BI Premium capacity (P SKU)**. Git integration is not available on shared/Pro-only workspaces.

### 2. Tenant admin setting

A Fabric/Power BI administrator must enable:

> **Admin portal → Tenant Settings → Git integration → "Users can synchronize workspace items with their Git repositories"** → **Enabled**

Optionally scope to specific security groups.

### 3. Git provider access

The identity performing the connection needs:

- **Azure DevOps**: Read/Write access to the target repository and branch. When using `Automatic` credentials (default for ADO), the SPN must have ADO project access. When using `ConfiguredConnection`, a pre-configured Fabric connection to ADO must exist.
- **GitHub**: A `ConfiguredConnection` with a Fabric Connection ID is **required**. Automatic credentials are **not supported** for GitHub with service principals.

### 4. Permissions

| Principal | Required Role | Target |
|---|---|---|
| Deployment SPN | **Workspace Admin** | On each target Fabric workspace (required for Connect, Disconnect, Initialize) |
| Deployment SPN | **Contributor** or higher | On each target Fabric workspace (required for Get Status, Commit, Update) |
| Deployment SPN | Repository access | Read/Write on the Git repository and branch |

### 5. Required Delegated Scopes

| Operation | Scope |
|---|---|
| Connect / Disconnect | `Workspace.ReadWrite.All` |
| Initialize Connection | `Workspace.ReadWrite.All` |
| Get Connection | `Workspace.Read.All` or `Workspace.ReadWrite.All` |
| Get Status | `Workspace.GitUpdate.All` or `Workspace.GitCommit.All` |
| Commit To Git | `Workspace.GitCommit.All` |
| Update From Git | `Workspace.GitUpdate.All` |

### 6. Limitations

- When using `Automatic` credentials source, the Connect API is **blocked for GitHub provider and for Service Principal**.
- For Service Principal / Managed Identity, use `ConfiguredConnection` credentials source.
- Commit To Git and Update From Git with SPN are only supported when **all items involved in the operation support service principals**.

## Idempotency Strategy

The script must be safe to re-run without side effects:

1. **GET** current connection state via `GET .../git/connection`
2. **Compare** current vs. desired:
   - `NotConnected` → connect + initialize + sync
   - `Connected` (but not initialized) → initialize + sync
   - `ConnectedAndInitialized` with **matching** provider details → skip connect, optionally sync
   - `ConnectedAndInitialized` with **different** provider details → disconnect + reconnect + initialize + sync
3. **Sync** based on `initializationStrategy` and `requiredAction` from Initialize Connection

### Connection State Machine

```
                    ┌────────────────────┐
                    │   NotConnected     │
                    └────────┬───────────┘
                             │ POST .../git/connect
                             ▼
                    ┌────────────────────┐
                    │   Connected        │
                    └────────┬───────────┘
                             │ POST .../git/initializeConnection
                             ▼
              ┌──────────────────────────────────┐
              │   requiredAction returned        │
              ├──────────────────────────────────┤
              │ None         → done              │
              │ UpdateFromGit → POST updateFromGit│
              │ CommitToGit  → POST commitToGit  │
              └──────────────┬───────────────────┘
                             │
                             ▼
                    ┌────────────────────┐
                    │ConnectedAndInit'd  │
                    └────────────────────┘
```

## Error Scenarios

| Error Code | Meaning | Recovery |
|---|---|---|
| `WorkspaceAlreadyConnectedToGit` | Connect called on already-connected workspace | Disconnect first, then reconnect |
| `WorkspaceNotConnectedToGit` | Initialize/Status/Commit/Update on unconnected workspace | Connect first |
| `WorkspaceHasNoCapacityAssigned` | Workspace not on capacity | Ensure workspace is assigned to capacity in Deploy-Workspaces step |
| `WorkspaceHeadMismatch` | Stale `workspaceHead` passed | Re-fetch status and retry with current head |
| `WorkspacePreviousOperationInProgress` | Another Git operation is running | Wait and retry with exponential backoff |
| `MissingInitializationPolicy` | Initialize called without strategy when both sides have content | Provide `initializationStrategy` |
| `InsufficientPrivileges` | SPN lacks admin role | Ensure Deploy-Security has run and SPN has Admin role |
| `PrincipalTypeNotSupported` | Using automatic credentials with SPN | Switch to `ConfiguredConnection` |

## Implementation Plan

### 1. Config Schema — Add `gitIntegration` block per workspace

Add an optional `gitIntegration` block under each workspace in the environment YAML:

#### Azure DevOps provider

```yaml
workspaces:
  - name: FIN-Core-Dev
    description: Finance core development workspace
    # ... existing items, roles, privateLink blocks ...

    gitIntegration:
      provider: AzureDevOps
      organizationName: MyOrg
      projectName: MyProject
      repositoryName: fabric-items
      branchName: main
      directoryName: FIN-Core-Dev.Workspace   # relative path in the repo

      # Optional: Fabric Connection ID for ConfiguredConnection credentials.
      # Required for SPN/MI auth with Azure DevOps, and always for GitHub.
      # Omit to use Automatic credentials (interactive/user auth only).
      connectionId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

      # Strategy when both workspace and remote have content during init.
      # PreferRemote | PreferWorkspace | None (default: PreferRemote)
      initializationStrategy: PreferRemote

      # Conflict resolution policy during Update From Git.
      # PreferRemote | PreferWorkspace (default: PreferRemote)
      conflictResolutionPolicy: PreferRemote

      # Whether to allow overriding existing items on Update From Git.
      # true | false (default: true)
      allowOverrideItems: true
```

#### GitHub provider

```yaml
workspaces:
  - name: FIN-Core-Dev
    description: Finance core development workspace

    gitIntegration:
      provider: GitHub
      ownerName: my-org
      repositoryName: fabric-items
      branchName: main
      directoryName: FIN-Core-Dev.Workspace

      # Required for GitHub (Automatic credentials not supported for SPN)
      connectionId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

      initializationStrategy: PreferRemote
      conflictResolutionPolicy: PreferRemote
      allowOverrideItems: true
```

#### Disconnect explicitly

```yaml
workspaces:
  - name: FIN-Sandbox-Dev
    description: Sandbox workspace — no Git integration
    gitIntegration: false   # explicitly disconnect if currently connected
```

### 2. Config Validation — Update `Read-EnvironmentConfig.ps1`

Add validation for the `gitIntegration` block:

```powershell
foreach ($ws in $config.workspaces) {
    if ($ws.PSObject.Properties.Name -contains 'gitIntegration') {
        $git = $ws.gitIntegration

        # Allow explicit false/null to skip
        if ($git -eq $false -or $null -eq $git) { continue }

        # Validate provider
        if (-not ($git.PSObject.Properties.Name -contains 'provider')) {
            throw "workspaces[$i].gitIntegration.provider is required."
        }
        $validProviders = @('AzureDevOps', 'GitHub')
        if ($git.provider -notin $validProviders) {
            throw "workspaces[$i].gitIntegration.provider must be one of: $($validProviders -join ', ')"
        }

        # Validate common required fields
        foreach ($field in @('repositoryName', 'branchName')) {
            if (-not ($git.PSObject.Properties.Name -contains $field) -or -not $git.$field) {
                throw "workspaces[$i].gitIntegration.$field is required."
            }
        }

        # Validate provider-specific fields
        if ($git.provider -eq 'AzureDevOps') {
            foreach ($field in @('organizationName', 'projectName')) {
                if (-not ($git.PSObject.Properties.Name -contains $field) -or -not $git.$field) {
                    throw "workspaces[$i].gitIntegration.$field is required for AzureDevOps provider."
                }
            }
        } elseif ($git.provider -eq 'GitHub') {
            if (-not ($git.PSObject.Properties.Name -contains 'ownerName') -or -not $git.ownerName) {
                throw "workspaces[$i].gitIntegration.ownerName is required for GitHub provider."
            }
            # connectionId is required for GitHub with SPN
            if (-not ($git.PSObject.Properties.Name -contains 'connectionId') -or -not $git.connectionId) {
                throw "workspaces[$i].gitIntegration.connectionId is required for GitHub provider."
            }
        }

        # Validate optional enum fields
        if ($git.PSObject.Properties.Name -contains 'initializationStrategy') {
            $validStrategies = @('None', 'PreferRemote', 'PreferWorkspace')
            if ($git.initializationStrategy -notin $validStrategies) {
                throw "workspaces[$i].gitIntegration.initializationStrategy must be one of: $($validStrategies -join ', ')"
            }
        }

        if ($git.PSObject.Properties.Name -contains 'conflictResolutionPolicy') {
            $validPolicies = @('PreferRemote', 'PreferWorkspace')
            if ($git.conflictResolutionPolicy -notin $validPolicies) {
                throw "workspaces[$i].gitIntegration.conflictResolutionPolicy must be one of: $($validPolicies -join ', ')"
            }
        }
    }
}
```

### 3. New Script — `Deploy-GitIntegration.ps1`

Create `src/scripts/Deploy-GitIntegration.ps1`:

```powershell
#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently connects Fabric workspaces to Git repositories and performs
    initial synchronization.

.DESCRIPTION
    For each workspace with a 'gitIntegration' block in the config:
      1. Gets current Git connection state
      2. If not connected → connects to the configured repo/branch/directory
      3. Initializes the connection
      4. Follows the requiredAction (UpdateFromGit or CommitToGit)

    Supports Azure DevOps and GitHub providers. Uses ConfiguredConnection
    credentials when a connectionId is provided.

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.
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

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    # Skip if no gitIntegration block
    $hasGit = $workspaceConfig.PSObject.Properties.Name -contains 'gitIntegration'
    if (-not $hasGit) {
        Write-Verbose "  No gitIntegration config for: $wsName"
        continue
    }

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  Workspace '$wsName' not in workspace map. Skipping."
        continue
    }

    $wsId = $WorkspaceMap[$wsName]
    $gitConfig = $workspaceConfig.gitIntegration

    # ── Handle explicit disconnect ──────────────────────────────────────
    if ($gitConfig -eq $false) {
        Write-Host "  Checking Git disconnect for: $wsName"
        # Check current state
        $connResult = Invoke-FabCli -Arguments @(
            'api', "workspaces/$wsId/git/connection", '--output_format', 'json'
        )
        $conn = $connResult.Output | ConvertFrom-Json

        if ($conn.gitConnectionState -ne 'NotConnected') {
            Write-Host "    Disconnecting workspace from Git..."
            Invoke-FabCli -Arguments @(
                'api', '-X', 'post', "workspaces/$wsId/git/disconnect"
            )
            Write-Host "    Disconnected."
        } else {
            Write-Host "    Already disconnected."
        }
        continue
    }

    Write-Host "  Configuring Git integration for: $wsName"

    # ── 1. Get current connection state ─────────────────────────────────
    $connResult = Invoke-FabCli -Arguments @(
        'api', "workspaces/$wsId/git/connection", '--output_format', 'json'
    )
    $conn = $connResult.Output | ConvertFrom-Json

    # ── 2. Build desired provider details ───────────────────────────────
    $desiredProvider = @{
        gitProviderType = $gitConfig.provider
        repositoryName  = $gitConfig.repositoryName
        branchName      = $gitConfig.branchName
        directoryName   = if ($gitConfig.PSObject.Properties.Name -contains 'directoryName') {
            $gitConfig.directoryName
        } else { '' }
    }

    if ($gitConfig.provider -eq 'AzureDevOps') {
        $desiredProvider['organizationName'] = $gitConfig.organizationName
        $desiredProvider['projectName']      = $gitConfig.projectName
    } elseif ($gitConfig.provider -eq 'GitHub') {
        $desiredProvider['ownerName'] = $gitConfig.ownerName
    }

    # ── 3. Determine if reconnect is needed ─────────────────────────────
    $needsConnect = $false
    $needsDisconnectFirst = $false

    switch ($conn.gitConnectionState) {
        'NotConnected' {
            $needsConnect = $true
        }
        { $_ -in @('Connected', 'ConnectedAndInitialized') } {
            # Check if current connection matches desired
            $current = $conn.gitProviderDetails
            $mismatch = $false

            if ($current.gitProviderType -ne $desiredProvider.gitProviderType) { $mismatch = $true }
            if ($current.repositoryName -ne $desiredProvider.repositoryName)   { $mismatch = $true }
            if ($current.branchName -ne $desiredProvider.branchName)           { $mismatch = $true }
            if (($current.directoryName ?? '') -ne ($desiredProvider.directoryName ?? '')) { $mismatch = $true }

            if ($gitConfig.provider -eq 'AzureDevOps') {
                if ($current.organizationName -ne $desiredProvider.organizationName) { $mismatch = $true }
                if ($current.projectName -ne $desiredProvider.projectName)           { $mismatch = $true }
            } elseif ($gitConfig.provider -eq 'GitHub') {
                if ($current.ownerName -ne $desiredProvider.ownerName) { $mismatch = $true }
            }

            if ($mismatch) {
                Write-Host "    Current Git connection differs from desired. Reconnecting..."
                $needsDisconnectFirst = $true
                $needsConnect = $true
            } else {
                Write-Host "    Git connection already matches desired state."
            }
        }
    }

    # ── 4. Disconnect if needed ─────────────────────────────────────────
    if ($needsDisconnectFirst) {
        Invoke-FabCli -Arguments @(
            'api', '-X', 'post', "workspaces/$wsId/git/disconnect"
        )
        Write-Host "    Disconnected from previous Git connection."
    }

    # ── 5. Connect ──────────────────────────────────────────────────────
    if ($needsConnect) {
        $connectPayload = @{ gitProviderDetails = $desiredProvider }

        # Add credentials if connectionId specified
        $hasConnId = ($gitConfig.PSObject.Properties.Name -contains 'connectionId') -and $gitConfig.connectionId
        if ($hasConnId) {
            $connectPayload['myGitCredentials'] = @{
                source       = 'ConfiguredConnection'
                connectionId = $gitConfig.connectionId
            }
        }

        $payloadJson = $connectPayload | ConvertTo-Json -Depth 5 -Compress
        Write-Host "    Connecting to $($gitConfig.provider): $($gitConfig.repositoryName)/$($gitConfig.branchName)"

        Invoke-FabCli -Arguments @(
            'api', '-X', 'post',
            "workspaces/$wsId/git/connect",
            '-i', $payloadJson
        )
        Write-Host "    Connected."
    }

    # ── 6. Initialize connection ────────────────────────────────────────
    $needsInit = $needsConnect -or ($conn.gitConnectionState -eq 'Connected')

    if ($needsInit) {
        $strategy = if ($gitConfig.PSObject.Properties.Name -contains 'initializationStrategy') {
            $gitConfig.initializationStrategy
        } else { 'PreferRemote' }

        $initPayload = @{ initializationStrategy = $strategy } | ConvertTo-Json -Compress
        Write-Host "    Initializing connection (strategy: $strategy)..."

        $initResult = Invoke-FabCli -Arguments @(
            'api', '-X', 'post',
            "workspaces/$wsId/git/initializeConnection",
            '-i', $initPayload,
            '--output_format', 'json'
        )

        # Handle LRO polling if 202 returned
        # (Implementation note: Invoke-FabCli may need extension for LRO polling)

        $initResponse = $initResult.Output | ConvertFrom-Json
        $requiredAction = $initResponse.requiredAction

        Write-Host "    Required action: $requiredAction"

        # ── 7. Execute required action ──────────────────────────────────
        switch ($requiredAction) {
            'None' {
                Write-Host "    No sync required."
            }
            'UpdateFromGit' {
                $conflictPolicy = if ($gitConfig.PSObject.Properties.Name -contains 'conflictResolutionPolicy') {
                    $gitConfig.conflictResolutionPolicy
                } else { 'PreferRemote' }

                $allowOverride = if ($gitConfig.PSObject.Properties.Name -contains 'allowOverrideItems') {
                    [bool]$gitConfig.allowOverrideItems
                } else { $true }

                $updatePayload = @{
                    remoteCommitHash   = $initResponse.remoteCommitHash
                    conflictResolution = @{
                        conflictResolutionType   = 'Workspace'
                        conflictResolutionPolicy = $conflictPolicy
                    }
                    options = @{
                        allowOverrideItems = $allowOverride
                    }
                }
                # workspaceHead may be null after first init
                if ($initResponse.workspaceHead) {
                    $updatePayload['workspaceHead'] = $initResponse.workspaceHead
                }

                $updateJson = $updatePayload | ConvertTo-Json -Depth 5 -Compress
                Write-Host "    Updating workspace from Git (conflict policy: $conflictPolicy)..."

                Invoke-FabCli -Arguments @(
                    'api', '-X', 'post',
                    "workspaces/$wsId/git/updateFromGit",
                    '-i', $updateJson
                ) -MaxRetries 2

                Write-Host "    Update from Git complete."
            }
            'CommitToGit' {
                $commitPayload = @{
                    mode          = 'All'
                    workspaceHead = $initResponse.workspaceHead
                    comment       = "Initial commit from fabric-cicd-v2 [$Environment]"
                } | ConvertTo-Json -Depth 5 -Compress

                Write-Host "    Committing workspace to Git..."
                Invoke-FabCli -Arguments @(
                    'api', '-X', 'post',
                    "workspaces/$wsId/git/commitToGit",
                    '-i', $commitPayload
                ) -MaxRetries 2

                Write-Host "    Commit to Git complete."
            }
        }
    } else {
        Write-Host "    Connection already initialized. Skipping init + sync."
    }
}
```

### 4. Orchestrator Integration

Add `'gitintegration'` to `$Scope` validation set in `Deploy-FabricEnvironment.ps1`:

```powershell
[ValidateSet('all', 'workspaces', 'items', 'security', 'privatelinks', 'gitintegration')]
[string]$Scope = 'all',
```

Invoke **after** workspaces are created and **before** item deployment. Connecting a workspace to Git and syncing from the remote branch is an alternative to (or complements) `fab deploy` item deployment:

```
Deployment order:
  1. Authenticate
  2. Workspaces              ← must exist first
  3. Git Integration         ← NEW: connect + sync from remote
  4. Items                   ← fab deploy (for workspaces NOT using Git integration)
  5. Security
  6. Private Links
```

Add after the workspace deployment section:

```powershell
# ── 3b. Git Integration ────────────────────────────────────────────────────
if ($Scope -in @('all', 'gitintegration')) {
    Write-Host ""
    Write-Host "[3b/N] Configuring Git integration..."
    & (Join-Path $scriptsRoot 'Deploy-GitIntegration.ps1') `
        -Config       $config `
        -WorkspaceMap $workspaceMap `
        -Environment  $Environment
} else {
    Write-Host ""
    Write-Host "[3b/N] Skipping Git integration (scope: $Scope)."
}
```

### 5. LRO Polling Support

Several Git API operations (Initialize Connection, Update From Git, Commit To Git) can return `202 Accepted` for long-running operations. The `Invoke-FabCli` helper may need an extension to handle LRO:

```powershell
function Wait-FabLongRunningOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [int]$MaxWaitSeconds = 300,

        [int]$DefaultRetryAfterSeconds = 30
    )

    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        Start-Sleep -Seconds $DefaultRetryAfterSeconds
        $elapsed += $DefaultRetryAfterSeconds

        $statusResult = Invoke-FabCli -Arguments @(
            'api', "operations/$OperationId", '--output_format', 'json'
        )
        $status = $statusResult.Output | ConvertFrom-Json

        switch ($status.status) {
            'Succeeded' { return $status }
            'Failed'    { throw "LRO $OperationId failed: $($status.error.message)" }
            'Running'   { Write-Verbose "  LRO $OperationId still running ($elapsed s)..." }
        }
    }

    throw "LRO $OperationId timed out after $MaxWaitSeconds seconds."
}
```

Alternatively, check whether `fab api` automatically handles LRO polling. If it does (blocking until the operation completes), no additional helper is needed.

### 6. Pipeline Integration

Add `gitintegration` to the scope parameter in `deploy-environment.yml`:

```yaml
parameters:
  - name: scope
    type: string
    default: 'all'
    values:
      - all
      - workspaces
      - items
      - security
      - privatelinks
      - gitintegration
```

### 7. Validation

Extend `Validate-Deployment.ps1` to verify Git connection state:

```powershell
# Test: workspace Git connection matches desired state
foreach ($ws in $Config.workspaces) {
    if ($ws.PSObject.Properties.Name -contains 'gitIntegration' -and $ws.gitIntegration -ne $false) {
        $wsId = $WorkspaceMap[$ws.name]
        $connResult = Invoke-FabCli -Arguments @(
            'api', "workspaces/$wsId/git/connection", '--output_format', 'json'
        )
        $conn = $connResult.Output | ConvertFrom-Json

        It "Workspace '$($ws.name)' should be ConnectedAndInitialized" {
            $conn.gitConnectionState | Should -Be 'ConnectedAndInitialized'
        }

        It "Workspace '$($ws.name)' should be connected to correct repo" {
            $conn.gitProviderDetails.repositoryName | Should -Be $ws.gitIntegration.repositoryName
        }

        It "Workspace '$($ws.name)' should be on correct branch" {
            $conn.gitProviderDetails.branchName | Should -Be $ws.gitIntegration.branchName
        }
    }
}
```

## Relationship to Item Deployment (`fab deploy`)

Git Integration and `fab deploy` serve related but distinct purposes:

| Aspect | Git Integration (this plan) | `fab deploy` (existing) |
|---|---|---|
| **Mechanism** | Connects workspace to a live Git branch; syncs via Fabric API | CLI pushes local artifacts to workspace |
| **Source of truth** | Remote Git branch (ongoing sync) | Local file system (point-in-time push) |
| **Ongoing sync** | Yes — workspace stays linked to branch | No — one-time deployment |
| **Use case** | Development workspaces, branch-per-environment promotion | CI/CD pipelines deploying from build artifacts |
| **Scope** | Entire workspace (all items in the linked directory) | Configurable (`item_types_in_scope`, `find_replace`) |
| **Parameterization** | Via Git branch content (items on each branch are pre-parameterized) | Via `find_replace` rules in config |

A workspace can use **either** Git Integration **or** `fab deploy`, or potentially both (Git Integration for the connection + `fab deploy` for additional items not in the Git repo). The `Deploy-Items.ps1` script should skip workspaces that have a `gitIntegration` block unless the `items` block is also explicitly defined.

## References

- [Fabric REST API — Git](https://learn.microsoft.com/en-us/rest/api/fabric/core/git)
- [Fabric REST API — Git Connect](https://learn.microsoft.com/en-us/rest/api/fabric/core/git/connect)
- [Fabric REST API — Git Initialize Connection](https://learn.microsoft.com/en-us/rest/api/fabric/core/git/initialize-connection)
- [Fabric REST API — Git Update From Git](https://learn.microsoft.com/en-us/rest/api/fabric/core/git/update-from-git)
- [Fabric REST API — Git Commit To Git](https://learn.microsoft.com/en-us/rest/api/fabric/core/git/commit-to-git)
- [Fabric REST API — Git Get Status](https://learn.microsoft.com/en-us/rest/api/fabric/core/git/get-status)
- [Fabric REST API — Long Running Operations](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation)
- [Automate Git integration](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-automation)
- [Get started with Git integration](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-get-started)
- [Fabric CLI — API Command](https://microsoft.github.io/fabric-cli/commands/api/)
- [Fabric CLI — API Examples](https://microsoft.github.io/fabric-cli/examples/api_examples/)
