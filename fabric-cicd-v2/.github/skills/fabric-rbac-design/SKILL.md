---
name: fabric-rbac-design
description: 'RBAC and security patterns for fabric-cicd-v2 Fabric workspace deployments. Use when asking about role assignments, least privilege, principalType, service principal permissions, additive RBAC, remove role, fab acl, Fabric Admin vs workspace Admin, who needs what role, design RBAC, identity GUID, Entra Object ID, Group vs User vs ServicePrincipal, RBAC hierarchy, or deployment SPN scope.'
---

# Fabric RBAC Design Patterns

Security and role assignment patterns specific to fabric-cicd-v2. RBAC is managed in `src/scripts/Deploy-Security.ps1` using `fab acl` commands.

## Core Principles

### Additive by Default

Existing role assignments in Fabric that are NOT in the config are **preserved**. The deployment never removes roles unless explicitly marked:

```yaml
roles:
  - identity: "guid-here"
    role: Admin
    remove: true    # ← only this triggers removal
```

This is a safety design — prevents accidental lockouts from config drift.

### Entra Object IDs Only

All `identity` values must be **Entra Object ID GUIDs**. These formats are NOT accepted:
- UPNs (`user@contoso.com`)
- Display names (`John Doe`)
- Email addresses

```yaml
# Correct
- identity: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

# Wrong — will fail validation
- identity: "john.doe@contoso.com"
```

### `principalType` Is Informational

The `principalType` field (`User`, `Group`, `ServicePrincipal`) is for documentation only. The Fabric CLI works with Object IDs regardless of type. However, always include it for clarity.

## Role Hierarchy

| Role | Permissions | Typical Use |
|------|-------------|-------------|
| **Admin** | Full control: manage members, delete workspace, configure settings | Deployment SPN, workspace owners |
| **Member** | Create/edit items, share items, manage non-admin members | Developers, data engineers |
| **Contributor** | Create/edit items in workspace | Data analysts, report builders |
| **Viewer** | Read-only access to items | Business users, consumers |

### Inheritance

Roles are NOT inherited across workspaces. Each workspace has its own independent role assignments.

## Common RBAC Patterns

### Pattern 1: Standard Team Workspace

```yaml
roles:
  # Deployment service principal — needs Admin for full management
  - identity: "<deployment-spn-guid>"
    principalType: ServicePrincipal
    role: Admin

  # Team leads — can manage members and items
  - identity: "<team-leads-group-guid>"
    principalType: Group
    role: Member

  # Developers — can create and edit items
  - identity: "<developers-group-guid>"
    principalType: Group
    role: Contributor

  # Business consumers — read-only
  - identity: "<consumers-group-guid>"
    principalType: Group
    role: Viewer
```

### Pattern 2: Shared Production Workspace (Locked Down)

```yaml
roles:
  # Only the deployment SPN can modify
  - identity: "<deployment-spn-guid>"
    principalType: ServicePrincipal
    role: Admin

  # Everyone else is read-only
  - identity: "<all-users-group-guid>"
    principalType: Group
    role: Viewer
```

### Pattern 3: Revoking Access During Offboarding

```yaml
roles:
  - identity: "<former-employee-guid>"
    principalType: User
    role: Member
    remove: true    # explicitly revoke
```

### Pattern 4: Promoting a Role

To change a user from Contributor → Member, set the new role. Fabric CLI handles the update (no need to remove then add):

```yaml
- identity: "<user-guid>"
  principalType: User
  role: Member    # was Contributor, now Member
```

## Deployment Service Principal Permissions

### What the Deployment SPN Needs

| Level | Requirement | Why |
|-------|-------------|-----|
| **Fabric Tenant** | Fabric Admin OR specific API permissions | Create workspaces, manage tenant settings |
| **Target Workspaces** | Admin role | Deploy items, manage RBAC, configure settings |
| **Azure Subscription** | Contributor on resource group | Deploy Bicep templates (capacity, Key Vault, PLS/PE) |
| **Key Vault** | Key Vault Secrets User (if used) | Read deployment secrets |

### Fabric Admin vs Workspace Admin

- **Fabric Admin** — tenant-wide role in M365/Entra admin center. Can manage ALL workspaces, tenant settings, capacity assignments. Required for some Admin API operations.
- **Workspace Admin** — per-workspace role. Can manage that workspace's items, members, and settings.

The deployment SPN typically needs Fabric Admin for initial workspace creation, then workspace Admin for ongoing deployments.

### Minimal Privilege Approach

If Fabric Admin is too broad, grant the SPN:
1. Permission to create workspaces (Fabric tenant setting)
2. Admin on each specific workspace after creation (the creator gets Admin automatically)

## How Deploy-Security.ps1 Works

### Execution Flow

```
For each workspace with roles:
  1. fab acl get → retrieve current assignments (JSON)
  2. For each desired role:
     a. Find existing assignment for this identity
     b. If remove: true AND exists → fab acl rm
     c. If role matches → skip (already correct)
     d. If exists with different role → fab acl set (updates)
     e. If not exists → fab acl set (creates)
  3. Collect results: Added, Updated, Removed, Skipped, AlreadyAbsent
```

### Idempotency

- Running twice produces no changes on the second run (all assignments already match)
- "Removed" entries stay removed unless re-added to config
- Order of roles in config doesn't matter

## Best Practices

1. **Use Entra Groups over individual users** — easier to manage, audit, and scale
2. **One Group per role level** — e.g., `Fabric-Analytics-Dev-Contributors`, `Fabric-Analytics-Dev-Viewers`
3. **Consistent across environments** — same group structure in dev/tst/prd, different group GUIDs
4. **Document principalType** — even though it's informational, it aids troubleshooting
5. **Never give Admin to broad groups** — Admin can delete the workspace and all contents
6. **Use `remove: true` for offboarding** — don't just delete from config; add with `remove: true` to ensure revocation, then clean up the entry later

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `fab acl set` fails | Deploying SPN lacks Admin on workspace | Grant Admin to SPN |
| Identity not found | GUID is wrong or user was deleted | Verify in Entra portal |
| Role not applied | Workspace not in workspace map | Check Deploy-Workspaces ran first |
| Unexpected roles present | Additive model — roles not in config are preserved | Add `remove: true` to revoke |
