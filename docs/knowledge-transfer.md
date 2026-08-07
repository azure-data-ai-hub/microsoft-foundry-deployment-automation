# Knowledge Transfer Guide

## 1. Purpose

This document supports a knowledge-transfer (KT) session between the Microsoft delivery team and the Ford operations/engineering teams taking ownership of the Microsoft Foundry deployment automation framework. It maps each engagement success criterion to a live demonstration and provides an FAQ for common follow-up questions.

## 2. Suggested KT Session Agenda (90 minutes)

| Time | Topic | Reference |
|---|---|---|
| 0:00–0:10 | Engagement recap: success criteria & deliverables | This document §3 |
| 0:10–0:25 | Architecture walkthrough (resource model, Basic vs. Standard Agent Setup) | `docs/architecture.md` §2-3 |
| 0:25–0:35 | Live demo: deploy to DEV via Azure CLI | `docs/deployment-guide.md` §3 |
| 0:35–0:45 | Live demo: GitHub Actions pipeline (PR → validate → deploy-manual) | `docs/deployment-guide.md` §4 |
| 0:45–0:55 | Live demo: onboard a new model, then retire it (drift detection → opt-in prune) | `docs/model-lifecycle-demo.md`, `docs/deployment-guide.md` §5/§5.1 |
| 0:55–1:05 | Live demo: multi-region deployment pattern | `docs/deployment-guide.md` §6 |
| 1:05–1:15 | Entra ID / Apigee integration walkthrough | `docs/architecture.md` §4.1, `docs/deployment-guide.md` §7 |
| 1:15–1:25 | Operational handoff: monitoring, incident response, escalation | `docs/operational-handoff.md` |
| 1:25–1:30 | Q&A | — |

## 3. Success Criteria → Demonstration Mapping

| # | Success Criterion | How it's demonstrated | Reference |
|---|---|---|---|
| 1 | Deploy Azure AI Foundry resources using Bicep templates | `az deployment sub create` against `infra/main.bicep` + any `.bicepparam` file | `docs/deployment-guide.md` §3 |
| 2 | Deploy supported models through GitHub Actions | `deploy-foundry.yml` pipeline deploys the `foundryModelDeployments` array as part of every environment deployment | `docs/deployment-guide.md` §4 |
| 3 | Onboard new models through configuration-driven processes | Add a model entry to a `.bicepparam` file; no Bicep module code changes required. Retirement is the same file edit plus an explicit opt-in prune | `docs/architecture.md` §5/§5.1, `docs/deployment-guide.md` §5/§5.1, `docs/model-lifecycle-demo.md` |
| 4 | Support deployments across multiple Azure regions | `infra/prod.main.bicepparam` (eastus) + `infra/prod-secondary-region.main.bicepparam` (westus2); `region` workflow_dispatch input override | `docs/architecture.md` §6, `docs/deployment-guide.md` §6 |
| 5 | Utilize Entra ID-based authentication through Apigee integration | `deployApigeeIntegration` parameter provisions an Entra ID App Registration + Service Principal + RBAC grant for Apigee's OAuth2 client-credentials flow | `docs/architecture.md` §4.1, `docs/deployment-guide.md` §7 |
| 6 | Reuse the deployment framework for future Azure AI Foundry initiatives | Modular `infra/modules/*.bicep` design; environment/region are pure parameter changes | `docs/architecture.md` §7 |

## 4. Final Deliverables Checklist

| Deliverable | Location |
|---|---|
| Azure AI Foundry Bicep deployment framework | `infra/main.bicep`, `infra/modules/*.bicep` |
| Model deployment automation framework | `foundryModelDeployments` parameter + `modules/foundry.bicep`; lifecycle reconciliation in `.github/workflows/deploy-foundry.yml` |
| GitHub Actions CI/CD workflows | `.github/workflows/deploy-foundry.yml` |
| Parameter and configuration templates | `infra/dev.main.bicepparam`, `infra/dev-standard.main.bicepparam`, `infra/stg.main.bicepparam`, `infra/prod.main.bicepparam`, `infra/prod-secondary-region.main.bicepparam` |
| Architecture documentation | `docs/architecture.md` |
| Deployment guide | `docs/deployment-guide.md` |
| Operational handoff documentation | `docs/operational-handoff.md` |
| Solution demonstration and KT session materials | `docs/knowledge-transfer.md` (this document), `docs/model-lifecycle-demo.md` |

## 5. Frequently Asked Questions

**Q: Do we need Standard Agent Setup for every environment?**
A: No. Basic Agent Setup (the default) is sufficient for most environments; Standard is only needed when you require direct control over Agent backing storage (networking, backup, compliance). See `docs/architecture.md` §3 for the decision guidance.

**Q: What happens if I add a model that isn't available in my region?**
A: The deployment will fail with a capacity/availability error from the Cognitive Services RP. Always check `az cognitiveservices model list --location <region>` before adding a model to a region's parameter file.

**Q: If I remove a model from the `.bicepparam` file, does it get deleted from Azure?**
A: No — not by the deployment itself. ARM runs in **Incremental** mode, which only creates and updates what's in the template and never deletes resources removed from it. (`Complete` mode would, but it is not usable here: this is a subscription-scoped deployment, so Complete mode would delete every resource group in the subscription absent from the template.) Instead, every successful `deploy-manual` run finishes with a **Reconcile model deployments** step that diffs the parameter file against the live deployments and reports any orphans as warnings, including the exact `az` command to remove each one. To actually delete them, re-run the workflow with the **`pruneOrphanedModels`** input checked. Deletion is deliberately a separate, explicit action — on `STG`/`PROD` it also passes through the Environment approval gate.

**Q: Why isn't deletion automatic?**
A: Deleting a model deployment is immediately breaking — any caller using that deployment name starts receiving `404 DeploymentNotFound` the moment it completes, with no grace period and no undo. Making it opt-in means a routine deploy can never drop a model by accident. See `docs/deployment-guide.md` §5.1 for the recommended retirement sequence (repoint callers → confirm zero traffic → remove from the parameter file → verify the warning → prune).

**Q: Do orphaned model deployments cost us anything?**
A: They consume no tokens, but each one continues to hold its `sku.capacity` allocation against the subscription's regional TPM quota. Left unreconciled, they cause quota failures on *unrelated* future deployments — which is why drift is surfaced on every run rather than only when someone goes looking.

**Q: Does the Apigee integration store any secrets in source control or ARM state?**
A: No. The Bicep module only creates the App Registration/Service Principal and grants an RBAC role — no client secret is generated or stored by Bicep. Secrets/certificates are created manually post-deployment (`az ad app credential reset`) and should be stored in a secrets manager (e.g., Apigee's own credential store or Azure Key Vault), never committed to the repository.

**Q: Who needs to grant the Entra ID directory role for the Apigee module?**
A: Someone with **Privileged Role Administrator** or **Global Administrator** in Entra ID must grant the deploying CI service principal (or interactive user) the **Application Administrator** or **Cloud Application Administrator** directory role. This is separate from and in addition to Azure RBAC (Contributor/User Access Administrator).

**Q: How do we add a third region?**
A: Copy `infra/prod-secondary-region.main.bicepparam`, rename it, update `location`/`resourceGroupName`/globally-unique names, and either deploy directly with Azure CLI or via `deploy-manual` with a `region` override. See `docs/deployment-guide.md` §6.

**Q: Can this framework be reused for a non-Ford / different business unit's Foundry deployment?**
A: Yes — that is an explicit design goal (success criterion 6). Copy the repository, update `.bicepparam` files with the new environment's names/projects/models, and reuse `main.bicep`/`modules/*.bicep` unchanged.

**Q: What is the rollback strategy if a deployment introduces a regression?**
A: Because deployments are declarative (Bicep/ARM), the fix is to revert the `.bicepparam`/module change in git and redeploy — ARM will reconcile resources back to the prior declared state. There is no separate "rollback" pipeline; standard git revert + redeploy is the pattern. Irreversible actions (e.g., permanent resource deletion) are called out in `docs/operational-handoff.md` where applicable.
