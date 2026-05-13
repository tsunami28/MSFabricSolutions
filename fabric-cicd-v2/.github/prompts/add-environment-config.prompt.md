---
description: "Add a new environment config for fabric-cicd-v2. Use when creating dev.yml, tst.yml, prd.yml, or any new environment YAML file for Fabric deployment."
---

# Add Environment Configuration

## Context

Environment configs live at `config/environments/{env}.yml` and define the full desired state for one Fabric environment. The deployment scripts read these files and converge the target to match.

## Required Structure

```yaml
environment: <dev|tst|prd>
capacityName: <fabric-capacity-name>

# Optional: shared Private Link settings
privateLinks:
  tenantId: "<guid>"
  SubscriptionId: "<guid>"
  subnetId: "<full-arm-resource-id>"
  privateDnsZoneId: "<full-arm-resource-id>"
  location: <azure-region>
  resourceGroupName: <rg-name>

workspaces:
  - name: <WorkspaceName>
    description: <description>
    capacityOverride: null  # or override capacity name

    items:
      repository_directory: artifacts/<WorkspaceName>.Workspace
      # item_types_in_scope: [Lakehouse, DataPipeline]  # optional filter
      parameters:
        find_replace:
          - find_value: "PLACEHOLDER_VALUE"
            replace_value: "actual-value"

    roles:
      - identity: "<entra-object-id>"
        principalType: User|Group|ServicePrincipal
        role: Admin|Member|Contributor|Viewer
      - identity: "<entra-object-id>"
        principalType: Group
        role: Admin
        remove: true  # explicitly revoke

    privateLink:  # optional
      plsName: <private-link-service-name>
      peResourceName: <private-endpoint-name>
```

## Validation Rules

- `environment` must be exactly one of: `dev`, `tst`, `prd`
- `capacityName` is required — the Fabric CLI resolves names directly (no GUID needed)
- `workspaces` must contain at least one entry
- Each workspace `name` must be unique within the file
- `repository_directory` must exist and contain `<item-name>.<ItemType>/` subdirectories with `.platform` files
- `identity` in roles must be a valid Entra Object ID (GUID format)
- `principalType` must be: User, Group, or ServicePrincipal
- `role` must be: Admin, Member, Contributor, or Viewer

## Naming Conventions

- Environment suffix in workspace names: `-Dev`, `-Tst`, `-Prd`
- Follow the existing pattern from other environment files in the same directory
- Private Link names follow: `{prefix}-{env}-{domain}-pls` / `{prefix}-{env}-{domain}`

## After Creating

The config is validated at runtime by `Read-EnvironmentConfig.ps1`. Test locally:

```powershell
. src/helpers/Read-EnvironmentConfig.ps1
$config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev.yml'
```
