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
| Staging | `STG` | Required reviewer(s) | Basic | Pre-production validation |
| Production | `PROD` | Required reviewer(s) | Standard | Production workloads (primary region) |
| Production (secondary region) | `PROD-SECONDARY-REGION` (optional) | Required reviewer(s) | Standard | DR/multi-region production capacity |

## 3. Monitoring & Alerting

- **Application Insights** is deployed in every environment for the Foundry resource and Projects. Configure alert rules on:
  - Failed model deployment/inference requests (`FailedRequests` metric)
  - Token/quota throttling (`429` responses from Azure OpenAI/Foundry endpoints)
  - Latency (P95/P99 response time)
- **Azure Monitor / Log Analytics** — route diagnostic settings from the Foundry resource (and Standard Agent Setup resources: Cosmos DB, Storage, AI Search) to a central Log Analytics workspace for centralized querying (`azure_mcp-monitor` tool or `az monitor diagnostic-settings create`).
- **Role assignment drift** — periodically run `az deployment sub what-if` against each environment's `.bicepparam` file to detect out-of-band changes.

## 4. Scaling

- **Model deployment capacity** (`sku.capacity` in `foundryModelDeployments`) controls throughput units (TPM/RPM) per model deployment — increase via a `.bicepparam` change and redeploy; subject to regional quota.
- **Standard Agent Setup resources** (Cosmos DB, AI Search, Storage) — scale via their respective SKU/throughput parameters in `modules/cosmosdb.bicep`, `modules/aisearch.bicep`, `modules/storage.bicep`; review before high-traffic events.
- **Adding Foundry Projects** — append to the `projects` array parameter; no other changes needed (RBAC and, in Standard mode, capability hosts are provisioned per-project automatically).
- **Adding regions** — see `docs/deployment-guide.md` §6.

## 5. Incident Response

| Scenario | First response |
|---|---|
| Model inference failures / 5xx errors | Check Foundry resource health in Azure Portal; check Application Insights failure telemetry; check regional Azure service health. |
| 401/403 errors from consumers | Confirm caller identity has the correct RBAC role (e.g., **Cognitive Services OpenAI User**) on the Foundry resource; for Apigee-routed traffic, confirm the gateway's Entra ID token is valid and not expired. |
| Capacity/quota errors (429) | Check `az cognitiveservices usage list --location <region>`; request quota increase or redistribute traffic to a secondary region. |
| Deployment pipeline failure | Check the `validate`/`whatif`/`deploy-*` job logs in GitHub Actions; most common cause is a naming collision or missing RBAC permission on the CI service principal — see `docs/deployment-guide.md` §8. |
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

- All infrastructure changes go through a pull request with the automated `validate` + `whatif` checks; **What-If output must be reviewed** before merge/approval, especially for `STG`/`PROD`.
- Production deployments require GitHub Environment approval (configure required reviewers on the `PROD` GitHub Environment).
- Emergency/out-of-band changes use the `deploy-manual` workflow dispatch — still goes through the same Bicep validation, just skips the sequential dev→stg→prod gate.

## 9. Knowledge Retention

- This `docs/` folder (`architecture.md`, `deployment-guide.md`, `operational-handoff.md`, `knowledge-transfer.md`) is the canonical operational reference and should be kept current as the framework evolves.
- Module-level comments in `infra/modules/*.bicep` document non-obvious design decisions (e.g., why `disableLocalAuth` is set, why no client secret is generated for the Apigee app).
