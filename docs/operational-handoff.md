# Operational Handoff Documentation

## 1. Ownership Model

| Area | Owner | Responsibilities |
|---|---|---|
| Bicep templates / CI pipeline | Platform/Infrastructure team | Module changes, pipeline maintenance, Bicep version upgrades |
| Environment `.bicepparam` files | Application/workload team per environment | Model onboarding, project additions, region additions |
| Entra ID App Registrations (Apigee, OIDC federation) | Identity/Security team | Credential rotation, directory role grants, federated credential subject scoping |
| Azure subscription RBAC | Cloud Platform / Subscription owners | Granting Contributor + User Access Administrator to CI service principals |

## 2. Environments

| Environment | GitHub Environment | Approval gate | Agent Setup Mode | Typical purpose |
|---|---|---|---|---|
| Development | `DEV` | None | Basic | Feature development, rapid iteration |
| Development (Standard) | `DEV` (reused) | None | Standard | Testing Standard Agent Setup / BYO backing resources; deployed via the `DEV-STANDARD` workflow option, which reuses the `DEV` GitHub Environment's secrets and federated credential |
| Staging | `STG` | Required reviewer(s) | Basic | Pre-production validation |
| Production | `PROD` | Required reviewer(s) | Standard | Production workloads (primary region) |
| Production (secondary region) | `PROD-SECONDARY-REGION` (optional) | Required reviewer(s) | Standard | DR/multi-region production capacity |

## 3. Monitoring & Alerting

- **Application Insights** is deployed in every environment for the Foundry resource and Projects. Configure alert rules on:
  - Failed model deployment/inference requests (`FailedRequests` metric)
  - Token/quota throttling (`429` responses from Azure OpenAI/Foundry endpoints)
  - Latency (P95/P99 response time)
- **Azure Monitor / Log Analytics** — route diagnostic settings from the Foundry resource (and Standard Agent Setup resources: Cosmos DB, Storage, AI Search) to a central Log Analytics workspace for centralized querying (`azure_mcp-monitor` tool or `az monitor diagnostic-settings create`).
- **Role assignment drift** — periodically run `az deployment sub validate` (or `what-if` ad hoc via `az deployment sub what-if`) against each environment's `.bicepparam` file to detect out-of-band changes.
- **Model deployment drift** — detected automatically. Every successful `deploy-manual` run diffs the parameter file against the live deployments and reports any that exist in Azure but are no longer declared (see §5 and `docs/deployment-guide.md` §5.1). Note this diff is by *deployment name* only: a model or version changed in place under an existing name is not flagged, so review `az cognitiveservices account deployment list` output periodically as well.

## 4. Scaling

- **Model deployment capacity** (`sku.capacity` in `foundryModelDeployments`) controls throughput units (TPM/RPM) per model deployment — increase via a `.bicepparam` change and redeploy; subject to regional quota. Check headroom first with `az cognitiveservices usage list --location <region>`, since an increase beyond available quota fails the deployment mid-loop (models are provisioned serially via `@batchSize(1)`, so earlier models in the array will already have been updated).
- **Standard Agent Setup resources** (Cosmos DB, AI Search, Storage) — scale via their respective SKU/throughput parameters in `modules/cosmosdb.bicep`, `modules/aisearch.bicep`, `modules/storage.bicep`; review before high-traffic events.
- **Adding Foundry Projects** — append to the `projects` array parameter; no other changes needed (RBAC and, in Standard mode, capability hosts are provisioned per-project automatically).
- **Adding regions** — see `docs/deployment-guide.md` §6.

## 5. Incident Response

| Scenario | First response |
|---|---|
| Model inference failures / 5xx errors | Check Foundry resource health in Azure Portal; check Application Insights failure telemetry; check regional Azure service health. |
| 401/403 errors from consumers | Confirm caller identity has the correct RBAC role (e.g., **Cognitive Services OpenAI User**) on the Foundry resource; for Apigee-routed traffic, confirm the gateway's Entra ID token is valid and not expired. |
| Capacity/quota errors (429) | Check `az cognitiveservices usage list --location <region>`; request quota increase or redistribute traffic to a secondary region. Also check for orphaned model deployments still consuming quota — see the row below. |
| Quota exhausted by unused model deployments | Orphaned deployments (removed from `.bicepparam` but never deleted from Azure) continue to hold their `sku.capacity` against regional TPM quota. The `Reconcile model deployments` step in the latest `deploy-manual` run lists them; re-run with `pruneOrphanedModels` checked to reclaim the quota. |
| `404 DeploymentNotFound` immediately after a prune | A model deployment was deleted while still in use. There is no undo — re-add the entry to the `.bicepparam` file and redeploy to recreate it (subject to quota availability), and repoint the caller. See `docs/deployment-guide.md` §5.1 for the retirement sequence that avoids this. |
| Deployment pipeline failure | Check the `validate`/`deploy-manual` job logs in GitHub Actions; most common cause is a naming collision or missing RBAC permission on the CI service principal — see `docs/deployment-guide.md` §8. |
| Suspected credential compromise (Apigee gateway) | Rotate the App Registration's client secret/certificate immediately: `az ad app credential list --id <appId>` then `az ad app credential delete` / `az ad app credential reset`. No Bicep changes needed since secrets are never stored in IaC. |

## 6. Cost Management

- Model deployment `sku.capacity` directly drives cost — right-size per environment (dev/stg typically need far less capacity than prod).
- Standard Agent Setup adds Cosmos DB, AI Search, and Storage costs beyond Basic mode — only enable for environments that need it (see `docs/architecture.md` §3 decision guidance).
- Tag all resources (`tags` parameter, merged with defaults via the `mergedTags` variable in `infra/main.bicep`) with cost-center/owner metadata for chargeback reporting.
- Review the Azure Advisor cost recommendations periodically (`azure_mcp-advisor` tool or Azure Portal → Advisor → Cost).

## 7. Support Escalation

1. **Tier 1** — Application team on-call (check dashboards, restart/retry, check known-issues runbook above).
2. **Tier 2** — Platform/Infrastructure team (Bicep/pipeline issues, RBAC issues, capacity/quota requests).
3. **Tier 3** — Microsoft Support (Azure service incidents, Foundry platform bugs) via the Azure Portal support ticket, referencing the Foundry resource ID (`foundryId` output).

## 8. Change Management

- All infrastructure changes go through a pull request with the automated `validate` check; review the Bicep diff/plan before merge/approval, especially for `STG`/`PROD`.
- Production deployments require GitHub Environment approval (configure required reviewers on the `PROD` GitHub Environment).
- All deployments — including emergency/out-of-band changes — go through the `deploy-manual` workflow dispatch, which runs the same Bicep validation before deploying.
- **Destructive model deletions are opt-in.** Removing a model from a `.bicepparam` file never deletes it implicitly; a second, explicit `deploy-manual` run with `pruneOrphanedModels` checked is required. On `STG`/`PROD` that run also passes through the Environment approval gate, so deletion always has a named approver in the audit trail.

## 9. Knowledge Retention

- This `docs/` folder (`architecture.md`, `deployment-guide.md`, `model-lifecycle-demo.md`, `operational-handoff.md`, `knowledge-transfer.md`) is the canonical operational reference and should be kept current as the framework evolves.
- Module-level comments in `infra/modules/*.bicep` document non-obvious design decisions (e.g., why `disableLocalAuth` is set, why no client secret is generated for the Apigee app).
