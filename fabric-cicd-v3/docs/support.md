# Microsoft Support Ticket — Power BI Admin API SPN Authorization Failure in Pipeline

## Issue Summary

A service principal with the Fabric Administrator directory role and correct tenant settings can successfully call the Power BI Admin REST API when using a token acquired interactively (locally), but the same SPN using an identically scoped token acquired in an Azure DevOps pipeline receives `PowerBINotAuthorizedException` on every admin API call.

---

## Environment

| | |
|---|---|
| Tenant ID | `27853008-4653-4efc-8d91-230eb2e2cf1c` |
| SPN Object ID (service principal) | `d90a8101-b1eb-4c92-aa62-595b1a951d36` |
| SPN App ID | `8b44c3ef-061a-417f-9162-7080d42be058` |
| Affected endpoint | `https://wabi-west-europe-g-primary-redirect.analysis.windows.net/v1.0/myorg/admin/groups/<workspaceId>` |
| ADO agent | Microsoft-hosted, Ubuntu, outbound IP `4.233.117.73` |

---

## Prerequisites Verified

Every documented requirement for SPN access to the Power BI Admin API has been confirmed in place:

**Entra ID role**
- The SPN service principal object (`d90a8101-...`) is a **direct member** of the `Fabric Administrator` directory role — not via group, directly assigned.
- Confirmed via `Get-MgDirectoryRoleMember` — the SPN object ID appears as a direct member.

**Fabric tenant settings**
- "Service principals can access read-only admin APIs" — **enabled**, scoped to security group `dtc-fabric-admin-sg`.
- "Service principals can access admin APIs used for updates" — **enabled**.
- "Enhance admin APIs responses with detailed metadata" — **enabled**.
- The SPN is a member of `dtc-fabric-admin-sg` — confirmed in Entra ID portal.

**Token**
- Acquired via client credentials flow against `https://login.microsoftonline.com/<tenantId>/oauth2/v2.0/token`.
- Scope: `https://analysis.windows.net/powerbi/api/.default`.
- Token `aud`: `https://analysis.windows.net/powerbi/api` ✓
- Token `roles` claim: `["Tenant.ReadWrite.All", "Tenant.Read.All"]` ✓
- Token `oid`: matches SPN service principal object ID ✓

**Network**
- No private link or network restrictions configured on the Fabric tenant.
- ADO agent has full outbound internet access (confirmed via `api.ipify.org`).
- No IP allowlist configured.

---

## What Works

**Local / interactive — succeeds:**

Calling the admin API directly with the SPN token against the regional backend endpoint returns `200 OK` with correct workspace data:

```
GET https://wabi-west-europe-g-primary-redirect.analysis.windows.net/v1.0/myorg/admin/groups/<workspaceId>
Authorization: Bearer <spn-client-credentials-token>
→ 200 OK
```

Also confirmed working: listing all groups via `admin/groups?$top=10` against the same regional endpoint.

**User account — succeeds:**

Calling the same endpoints with a user account token (device code flow, user has Fabric Administrator role) returns `200 OK` from both `api.powerbi.com` and the regional endpoint.

---

## What Fails

**`api.powerbi.com` with SPN token — always fails:**

```
GET https://api.powerbi.com/v1.0/myorg/admin/groups?$top=10
Authorization: Bearer <spn-client-credentials-token>
→ 401 Unauthorized
```

This is a routing issue — `api.powerbi.com` does not correctly redirect SPN client-credentials tokens to the regional backend. User tokens redirect correctly; SPN tokens do not.

**Regional endpoint in ADO pipeline — fails:**

```
GET https://wabi-west-europe-g-primary-redirect.analysis.windows.net/v1.0/myorg/admin/groups/<workspaceId>
Authorization: Bearer <spn-client-credentials-token>
→ PowerBINotAuthorizedException
```

The same endpoint, the same SPN, the same token scope — works locally, fails in the pipeline.

---

## Token Comparison: Local vs Pipeline

Both tokens were decoded and compared. The `roles`, `oid`, `aud`, `tid`, and `appid` claims are identical. The following internal claims differ:

| Claim | Local (working) | Pipeline (failing) |
|---|---|---|
| `xms_act_fct` | `"9 3"` | `"3 9"` |
| `xms_sub_fct` | `"3 9"` | `"9 3"` |
| `xms_idrel` | `"7 18"` | `"7 30"` |
| `iat` / `exp` | Different (expected — different issuance times) | — |

The `xms_idrel` difference (`18` vs `30`) is notable. This field encodes the identity relationship context evaluated at token issuance. The different value suggests the Power BI authorization backend is evaluating the pipeline-issued token under a different identity context despite the SPN being identical.

**Hypothesis:** The Fabric Administrator role was assigned directly to the SPN service principal during this investigation session. The Power BI backend authorization cache may not have fully propagated this role assignment for SPN client-credentials tokens. User-delegated tokens appear to pick up role changes faster. The `xms_idrel` difference may reflect a cached vs uncached evaluation path.

---

## Reproduction Steps

1. Acquire a client-credentials token for SPN `8b44c3ef-...` with scope `https://analysis.windows.net/powerbi/api/.default`.
2. Call `GET https://wabi-west-europe-g-primary-redirect.analysis.windows.net/v1.0/myorg/admin/groups/<workspaceId>` with the token from a local machine → **200 OK**.
3. Execute the same call from an Azure DevOps Microsoft-hosted Ubuntu agent using an identically acquired token → **PowerBINotAuthorizedException**.

---

## Questions for Microsoft

1. What does the difference in `xms_idrel` (`18` vs `30`) indicate in the context of Power BI Admin API authorization? Does it affect how the backend evaluates role membership?
2. Is there a known propagation delay for direct Fabric Administrator role assignments to SPN service principals specifically for the Power BI Admin API authorization layer, separate from the Entra ID token issuance?
3. Why does `api.powerbi.com` return `401` for SPN client-credentials tokens on `admin/` endpoints while the regional backend accepts the same token (at least locally)? Is this by design or a known routing issue?
4. Is there any network-level or request-origin evaluation happening server-side on the Power BI Admin API that would differentiate requests from a Microsoft-hosted ADO agent vs a local workstation, given that no private link or IP restrictions are configured?