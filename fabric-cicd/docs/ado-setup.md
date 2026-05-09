# Azure DevOps Setup Guide

One-time setup steps required before the pipeline can run. Steps 1–3 are Azure-side; steps 4–6 are ADO-side.

---

## 1 — Create User-Assigned Managed Identities

Create three User-Assigned Managed Identities (UAMIs) in Azure — one per environment. Keep them in separate resource groups that align with your environment boundary.

```powershell
# Example — adjust subscription, resource group, and location
$environments = @('dev', 'tst', 'prd')
$resourceGroup = 'rg-fabric-identity'
$location = 'westeurope'

foreach ($env in $environments) {
    az identity create `
        --name "fabric-$env-mi" `
        --resource-group $resourceGroup `
        --location $location
}
```

Note the **Client ID** and **Object (Principal) ID** of each UAMI — you will need them in steps 4 and 5.

---

## 2 — Grant Each UAMI Access to Fabric

For each UAMI, a Fabric administrator must:

1. Enable **Service principals can use Fabric APIs** in the Fabric tenant settings (`Admin portal → Tenant settings → Developer settings`)
2. Add the UAMI's service principal to the target Fabric workspace(s) with the **Admin** role — either directly, or via a security group
3. Assign the UAMI to the Fabric capacity as a **Capacity Admin** or **Capacity Contributor** (Portal: `Fabric Capacity → Capacity settings → User management`)

> **Tip**: Grant the dev UAMI access to the dev capacity only; tst UAMI to the tst capacity only; prd UAMI to the prd capacity only. This enforces environment isolation.

---

## 3 — Record Fabric Capacity IDs

Open [config/shared/capacities.json](../config/shared/capacities.json) and replace the placeholder GUIDs with your real capacity IDs.

Capacity IDs can be found in the Azure portal under the Fabric Capacity resource → **Properties → Resource ID** (the last segment of the resource ID is the capacity GUID), or via:

```powershell
az resource list --resource-type "Microsoft.Fabric/capacities" --query "[].{name:name, id:id}" -o table
```

---

## 4 — Create ADO Service Connections

In Azure DevOps, go to **Project Settings → Service connections → New service connection → Azure Resource Manager → Workload identity federation (manual)**.

Create three connections:

| Service connection name | Identity |
|---|---|
| `sc-fabric-dev` | `fabric-dev-mi` client ID |
| `sc-fabric-tst` | `fabric-tst-mi` client ID |
| `sc-fabric-prd` | `fabric-prd-mi` client ID |

For each connection:
- **Subscription ID / Tenant ID**: your Azure subscription and tenant
- **Service principal ID**: the UAMI client ID (not object ID)
- **Grant access permission to all pipelines**: ✅ (or scope to this pipeline)

---

## 5 — Create ADO Variable Groups

In **Pipelines → Library → Variable groups**, create four groups:

### `vg-fabric-common`

| Variable | Value |
|---|---|
| `agentPoolName` | Name of the self-hosted agent pool (or `Azure Pipelines` for Microsoft-hosted) |
| `fabricTenantId` | Your Azure AD / Entra ID tenant GUID |

### `vg-fabric-dev`

| Variable | Value |
|---|---|
| `managedIdentityClientId` | Client ID of `fabric-dev-mi` |
| `fabricCapacityName` | Display name of the dev Fabric capacity (must match a key in `capacities.json`) |

### `vg-fabric-tst`

| Variable | Value |
|---|---|
| `managedIdentityClientId` | Client ID of `fabric-tst-mi` |
| `fabricCapacityName` | Display name of the tst Fabric capacity |

### `vg-fabric-prd`

| Variable | Value |
|---|---|
| `managedIdentityClientId` | Client ID of `fabric-prd-mi` |
| `fabricCapacityName` | Display name of the prd Fabric capacity |

Link each group to the pipeline: **Pipeline → Edit → Variables → Variable groups → Link variable group**.

> `managedIdentityClientId` does not need to be a secret variable — it is a non-sensitive identifier. Treat it as a secret only if your organisation's policy requires it.

---

## 6 — Create ADO Environments

In **Pipelines → Environments**, create three environments:

| ADO Environment | Approval gate |
|---|---|
| `fabric-dev` | None (auto-deploys) |
| `fabric-tst` | Add approval: 1 approver required |
| `fabric-prd` | Add approval: 1 approver required (consider requiring 2) |

To add an approval gate: open the environment → **Approvals and checks → Approvals → Add**. Select the user(s) or group(s) who must approve before the stage runs.

---

## 7 — Import the Deploy Pipeline

In **Pipelines → New pipeline → Azure Repos Git → Select repo → Existing Azure Pipelines YAML file**:

- Path: `fabric-cicd/pipelines/deploy-fabric.yml`

Save without running. On the first manual run, use **Dry Run = true** to verify everything is wired up without creating resources.

---

## 8 — Import the PR Validation Pipeline

In **Pipelines → New pipeline → Azure Repos Git → Select repo → Existing Azure Pipelines YAML file**:

- Path: `fabric-cicd/pipelines/pr-validate-fabric.yml`

Save and **allow** the pipeline when prompted about variable group access.

### Enable OAuth token access

The PR pipeline posts a comment on the PR using `System.AccessToken`. This requires the token to be accessible to scripts:

1. Open the PR pipeline → **Edit** → **⋮ More actions** → **Triggers** (or **Settings**)
2. Enable **Allow scripts to access OAuth token**

Alternatively, if your organisation disables OAuth tokens by default, a project admin can enable it in **Project Settings → Pipelines → Settings → Allow scripts to access the OAuth token by default**.

### Set as a required status check (branch policy)

1. Go to **Repos → Branches → `main` → Branch policies**
2. Under **Build validation**, click **+ Add build policy**
3. Select the PR validation pipeline
4. Set **Trigger** to *Automatic*
5. Set **Policy requirement** to *Required*
6. Set a display name (e.g. `Fabric PR Validation`)
7. Save

With this policy active, every PR to `main` must pass schema validation and the dry-run before it can be merged.

---

## 9 — Import the Drift Detection Pipeline

In **Pipelines → New pipeline → Azure Repos Git → Select repo → Existing Azure Pipelines YAML file**:

- Path: `fabric-cicd/pipelines/drift-detect-fabric.yml`

Save. The schedule (`0 5 * * 2` — Tuesdays 05:00 UTC) activates automatically once the pipeline is registered. To run manually, click **Run pipeline** and optionally set `remediate = true`.

No new service connections, variable groups, or ADO Environments are required — the drift pipeline reuses the resources created in steps 4–6.

> **Note:** Set **`always: true`** in the schedule block (already present in the YAML). This is what causes the pipeline to run even when no code changed since the last scheduled run — which is essential for detecting drift from manual Fabric changes.

---

## Verification Checklist

Before the first real deployment run:

- [ ] `capacities.json` updated with real GUIDs
- [ ] Parameter files updated with real principal names/IDs (no `contoso.com` placeholders)
- [ ] All 3 service connections created and tested (use **Verify** in ADO)
- [ ] All 4 variable groups created and linked to the pipeline
- [ ] All 3 ADO Environments created; tst and prd have approval reviewers configured
- [ ] UAMI has **Member or Admin** role on each Fabric workspace it will manage
- [ ] Fabric tenant setting **Service principals can use Fabric APIs** is enabled
- [ ] Dry-run pipeline completed successfully for `dev` environment
- [ ] PR validation pipeline imported and **Allow scripts to access OAuth token** enabled
- [ ] Branch policy on `main` set to require the PR validation pipeline
- [ ] Drift detection pipeline imported; verify it runs correctly on next Tuesday or trigger a manual run
