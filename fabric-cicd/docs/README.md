# Fabric CI/CD - Documentation

This folder contains the operational and architectural documentation for the Fabric CI/CD solution.

| Document | Description |
|---|---|
| [architecture.md](architecture.md) | Solution architecture, component map, and design decisions |
| [pipeline-guide.md](pipeline-guide.md) | How the Azure DevOps pipeline works and how to run it |
| [ado-setup.md](ado-setup.md) | One-time Azure DevOps and Azure setup steps (service connections, variable groups, environments) |
| [auth-design.md](auth-design.md) | Authentication flow - Managed Identity, Az.Accounts, and Fabric token acquisition |
| [parameter-files.md](parameter-files.md) | How to author and maintain environment parameter files |

---

## Phase 1 Deliverables

Phase 1 establishes the full foundation for automated Fabric resource deployment using Azure DevOps. All core components are functional and production-ready.

See [architecture.md](architecture.md) for the complete picture and [ado-setup.md](ado-setup.md) for the steps required before the first pipeline run.
