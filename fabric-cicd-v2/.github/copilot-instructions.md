# Copilot Instructions for fabric-cicd-v2

## Project Overview

This is a **PowerShell + Fabric CLI** (`ms-fabric-cli`) solution that deploys Microsoft Fabric resources (workspaces, items, RBAC, and Private Link infrastructure) across `dev → tst → prd` environments via Azure DevOps pipelines.

## Technology Stack

- **PowerShell 7.0+** — All deployment scripts use `#Requires -Version 7.0`
- **Fabric CLI** (`fab`) — Python-based CLI from `ms-fabric-cli` package
- **Azure Bicep** — Infrastructure deployments (capacity, Key Vault, PLS/PE)
- **Azure DevOps YAML Pipelines** — CI/CD orchestration
- **YAML configuration** — Environment definitions parsed with `powershell-yaml` module

## Repository Structure

```
fabric-cicd-v2/
├── config/environments/       # Per-environment split-file directories (dev/, tst/, prd/)
│   ├── dev/
│   │   ├── _env.yml           # Environment-level settings + gateways
│   │   └── <Workspace>.yml    # One file per workspace
│   ├── tst/
│   └── prd/
├── config/shared/             # Shared reference data
│   ├── capacities.yml         # Capacity definitions
│   ├── defaults.yml           # Shared privateLinks base values
│   └── roles-common.yml       # RBAC identities injected into every workspace
├── parameters/                # Bicep parameter files per project/region/env
├── pipelines/                 # ADO pipeline definitions
│   ├── deploy-fabric.yml      # Main pipeline
│   └── templates/             # Reusable step templates
├── src/
│   ├── helpers/               # Shared utility functions (dot-sourced)
│   │   ├── Invoke-FabCli.ps1         # fab CLI wrapper with retry logic
│   │   ├── Read-EnvironmentConfig.ps1 # YAML config loader/validator
│   │   └── New-FabDeployConfig.ps1    # fab deploy config generator
│   └── scripts/               # Deployment scripts
│       ├── Deploy-FabricEnvironment.ps1  # Main orchestrator (entry point)
│       ├── Deploy-Workspaces.ps1         # Workspace create/update
│       ├── Deploy-Items.ps1              # Item deployment via fab deploy
│       ├── Deploy-Security.ps1           # RBAC role assignments
│       ├── Deploy-PrivateLinks.ps1       # PLS + PE via Bicep
│       └── Validate-Deployment.ps1       # Post-deployment NUnit validation
└── docs/                      # Planning and design documents
```

## Coding Conventions

### PowerShell Scripts

- Always include `#Requires -Version 7.0` at the top
- Use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`
- Use `[CmdletBinding()]` with proper `param()` blocks
- Include proper `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and `.EXAMPLE` comment-based help
- Use `[OutputType()]` attribute on functions
- Validate parameters with `[ValidateSet()]`, `[ValidateNotNullOrEmpty()]`, `[ValidateScript()]`
- Helpers are dot-sourced from `src/helpers/` — never use `Import-Module` for project scripts
- All operations must be **idempotent** — safe to re-run without side effects
- Use `Write-Host` for progress messages, `Write-Verbose` for debug detail, `Write-Warning` for non-fatal issues

### Fabric CLI Usage

- Wrap all `fab` calls via the `Invoke-FabCli` helper function
- Use `-AllowNonZeroExit` when checking existence (`fab exists`)
- JSON output: pass `--output_format json` in arguments
- Exit codes: 0=success, 2=auth error (never retry), 1/3+=transient (retry with backoff)
- Use exponential backoff retry for transient failures (configurable via `-MaxRetries`)

### Environment Configuration (YAML)

- Environment configs live as **split-file directories** at `config/environments/{env}/`
- Each directory contains `_env.yml` (environment level) + one `<WorkspaceName>.yml` per workspace
- Shared `privateLinks` base values are in `config/shared/defaults.yml`
- Common RBAC identities for all workspaces are in `config/shared/roles-common.yml`
- `Read-EnvironmentConfig -ConfigPath config/environments/dev/` merges all layers at load time
- Legacy single-file path (e.g. `config/environments/dev.yml`) is still accepted for backward compatibility
- Required `_env.yml` fields: `environment`, `capacityName`
- Required workspace file fields: `name`
- Valid environments: `dev`, `tst`, `prd`
- Workspace blocks contain: `name`, `description`, `capacityOverride`, `items`, `roles`, `privateLink`, `gitIntegration`
- Item deployment uses `repository_directory` pointing to Fabric Git Integration folder structure
- RBAC uses Entra Object IDs with `principalType` (User, Group, ServicePrincipal) and `role` (Admin, Member, Contributor, Viewer)
- Set `skipCommonRoles: true` on a workspace to opt out of common-role injection from `roles-common.yml`

### Azure DevOps Pipelines

- Main pipeline: `pipelines/deploy-fabric.yml`
- Use parameterized templates in `pipelines/templates/`
- Variable groups: `project-variables`, `fabric-variables`
- ADO Environments with approval gates: `fabric-dev`, `fabric-tst`, `fabric-prd`
- Secrets are passed via variable group references, never hardcoded

## Authentication Patterns

Two mutually exclusive methods:
1. **Service Principal** — `-ClientId`, `-ClientSecret`, `-TenantId`
2. **Managed Identity** — `-UseManagedIdentity` (optionally `-ManagedIdentityClientId`)

## Key Design Principles

- **Idempotent deployments** — All scripts converge to desired state without side effects
- **Additive RBAC** — Existing roles not in config are preserved (unless `remove: true`)
- **Single-source artifacts** — All environments can deploy from the same item source directory with `find_replace` parameterization
- **Scoped execution** — The `-Scope` parameter allows deploying only specific phases (workspaces, items, security, privatelinks)
- **Structured error handling** — Exit codes propagated, stderr captured, retries for transient failures only

## When Adding New Features

1. New deployment phases go in `src/scripts/Deploy-*.ps1`
2. New helpers go in `src/helpers/`
3. Configuration changes require updating `Read-EnvironmentConfig.ps1` validation
4. Pipeline changes use template pattern in `pipelines/templates/`
5. Add planning/design docs to `docs/` before implementation
6. Always include NUnit validation tests in `Validate-Deployment.ps1`
