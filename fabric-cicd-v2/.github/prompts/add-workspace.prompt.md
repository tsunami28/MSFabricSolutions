---
description: "Add new workspace or extend workspace configuration in fabric-cicd-v2 environment files. Use when onboarding a new Fabric workspace to the deployment pipeline."
---

# Add Workspace to Deployment

## Steps to Onboard a New Workspace

### 1. Export Items from Fabric (if items exist)

Use Fabric Git Integration to export workspace items:
1. Connect the workspace to a Git repo branch
2. Export/sync items to the repo
3. Items land in `artifacts/<WorkspaceName>.Workspace/` with the standard structure:
   ```
   artifacts/<WorkspaceName>.Workspace/
   ├── <ItemName>.<ItemType>/
   │   ├── .platform
   │   └── <content-files>
   ```

### 2. Add Workspace to Environment Config

Add a new entry under `workspaces:` in each environment YAML:

```yaml
  - name: <WorkspaceName-Env>
    description: <purpose of this workspace>
    capacityOverride: null  # or specific capacity name

    items:
      repository_directory: artifacts/<WorkspaceName-Dev>.Workspace
      parameters:
        find_replace:
          - find_value: "DEV_PLACEHOLDER"
            replace_value: "environment-specific-value"

    roles:
      - identity: "<admin-group-object-id>"
        principalType: Group
        role: Admin
      - identity: "<developer-group-object-id>"
        principalType: Group
        role: Member
      - identity: "<reader-group-object-id>"
        principalType: Group
        role: Viewer

    # Optional: add private link
    privateLink:
      plsName: <naming-convention>-pls
      peResourceName: <naming-convention>
```

### 3. Environment-Specific Values

For `find_replace` parameterization across environments:
- Use placeholders in the source artifacts (e.g., `PLACEHOLDER_LAKEHOUSE_ID`)
- Define environment-specific replacements in each env YAML
- All environments point to the **same** source directory — replacements handle differences

### 4. RBAC Planning

Standard role pattern:
| Group | Role | Purpose |
|---|---|---|
| `{prefix}-admin` | Admin | Full workspace management |
| `{prefix}-developer` | Member | Create/edit items |
| `{prefix}-reader` | Viewer | Read-only access |
| SPN for deployment | Admin | Required for pipeline operations |

### 5. Validate

```powershell
# Validate config parses correctly
. src/helpers/Read-EnvironmentConfig.ps1
$config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev.yml'
$config.workspaces | Select-Object name

# Test workspace creation (dry run concept)
fab exists "<WorkspaceName>.Workspace"
```

### 6. Private Link (Optional)

If the workspace needs private connectivity:
1. Add `privateLink` block to the workspace config
2. Ensure top-level `privateLinks` section has shared settings (subnet, DNS zone, etc.)
3. The `Deploy-PrivateLinks.ps1` script handles PLS + PE creation via Bicep

## Naming Conventions

- Workspace names: `{Domain}-{Function}-{Env}` (e.g., `FIN-Core-Dev`)
- Private Link Service: `{prefix}-{env}-{domain}-pls`
- Private Endpoint: `{prefix}-{env}-{domain}`
- Follow existing patterns in the environment files
