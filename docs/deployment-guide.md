# Deployment Guide

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Azure subscription(s) | One per environment (dev/stg/prod) or one shared subscription with separate resource groups — both patterns are supported. |
| Azure CLI | [Install](https://learn.microsoft.com/cli/azure/install-azure-cli). Bicep CLI 0.20+ is bundled; run `az bicep upgrade` if needed. |
| Azure Developer CLI (azd) | [Install](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) — optional, for local interactive deploys. |
| Permissions | **Contributor** + **User Access Administrator** (or **Owner**) scoped to the target resource group for the identity that deploys (needed for `deployRoleAssignments = true`), plus rights to create/verify the resource group itself (either subscription-level `Microsoft.Resources/subscriptions/resourcegroups/write`, or the resource group can be pre-created by someone else — see §3.1a). |
| GitHub repository | With Actions enabled and OIDC federation configured for Azure (§4). |
| (Optional) Entra ID directory role | **Application Administrator** or **Cloud Application Administrator**, required only if `deployApigeeIntegration = true` (creates an Entra ID App Registration + Service Principal). |

## 2. Repository Layout Reference

```
infra/
├── main.bicep                          # Subscription-scoped orchestrator
├── modules/                            # Reusable Bicep modules
├── dev.main.bicepparam                 # Dev (Basic Agent Setup)
├── stg.main.bicepparam                 # Staging (Basic Agent Setup)
├── prod.main.bicepparam                # Production, eastus (Standard Agent Setup)
└── prod-secondary-region.main.bicepparam  # Production, westus2 (multi-region example)
azure.yaml                              # azd project config
.github/workflows/deploy-foundry.yml    # CI/CD pipeline
docs/                                   # This documentation set
```

## 3. Step-by-Step: First-Time Deployment

### 3.1 Clone and customize parameters

1. Clone the repository.
2. Open `infra/dev.main.bicepparam` (and `stg`/`prod` as needed) and set **globally unique** names:
   - `namePrefix` (max 10 characters)
   - If using Standard Agent Setup: `kvName`, `storageName`, `cosmosDBName`, `aiSearchName`
3. Review/adjust `location`, `resourceGroupName`, `projects`, and `foundryModelDeployments` for each environment.
4. Confirm target models are available in your target region:
   ```powershell
   az cognitiveservices model list --location eastus --query "[].{model:model.name, version:model.version}" -o table
   ```

### 3.1a Create the resource group

> **Important:** `main.bicep` never creates its own resource group — it always deploys **into** an
> existing one referenced by `resourceGroupName`. This keeps the deploying identity's required
> Azure RBAC scoped to that resource group (Contributor/User Access Administrator) rather than
> needing subscription-wide resource-group-write rights. The resource group must exist *before*
> running `az deployment sub validate`/`create` or the GitHub Actions pipeline.

```powershell
az group create --name dev-mfd-foundry-rg --location eastus
```

The GitHub Actions pipeline (§4) does this automatically via an `az group create` step (idempotent
— safe to re-run, no-op if the group already exists) that reads `resourceGroupName`/`location`
directly from each environment's `.bicepparam` file, so you don't need to pre-create the resource
group yourself for CI/CD-driven deployments — only for local `az deployment sub` runs.

### 3.2 Validate locally

```powershell
az login
az account set --subscription "<your-subscription-id>"

az deployment sub validate `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/dev.main.bicepparam
```

### 3.3 Deploy locally (Azure CLI)

```powershell
az deployment sub create `
  --location eastus `
  --name foundry-dev-deployment `
  --template-file infra/main.bicep `
  --parameters infra/dev.main.bicepparam
```

### 3.4 Deploy locally (azd)

```powershell
winget install microsoft.azd
az login
azd env new dev
azd up
```

`azd` prompts for subscription/resource group/location bindings, reading defaults from `azure.yaml`.

### 3.5 Verify

```powershell
az deployment sub show --name foundry-dev-deployment --query "properties.outputs"
```

Check the `foundryEndpoint`, `foundryId`, and (if Standard Agent Setup) the Key Vault/Storage/Cosmos DB/AI Search outputs.

## 4. GitHub Actions CI/CD Setup

### 4.1 Configure OIDC federation (no stored secrets)

For each GitHub Environment (`DEV`, `STG`, `PROD`, and optionally `PROD-SECONDARY-REGION`):

```powershell
az ad app create --display-name "microsoft-foundry-deployment-automation-<env>"
$appId = az ad app list --display-name "microsoft-foundry-deployment-automation-<env>" --query "[0].appId" -o tsv
az ad sp create --id $appId

az ad app federated-credential create --id $appId --parameters '{
  "name": "github-<env>",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:environment:<ENV_NAME>",
  "audiences": ["api://AzureADTokenExchange"]
}'

az role assignment create --assignee $appId --role "Contributor" --scope "/subscriptions/<sub-id>"
az role assignment create --assignee $appId --role "User Access Administrator" --scope "/subscriptions/<sub-id>"
```

> **Least-privilege alternative:** since `main.bicep` never creates its own resource group (§3.1a),
> the subscription-wide roles above can be replaced with: (1) a custom role granting only
> `Microsoft.Resources/deployments/*` and `Microsoft.Resources/subscriptions/resourcegroups/read`
> at subscription scope (enough to submit `az deployment sub create`), plus (2) the CI/CD pipeline's
> own identity needs `Microsoft.Resources/subscriptions/resourcegroups/write` at subscription scope
> to run its `az group create` step (§4.3) — or pre-create all environment resource groups once,
> out-of-band, and grant (3) Contributor + User Access Administrator scoped to each resource group
> only. See `docs/architecture.md` for more on this pattern.

### 4.2 Create GitHub Environments

In repo **Settings → Environments**, create `DEV`, `STG`, `PROD` (and `PROD-SECONDARY-REGION` if using the secondary-region example). For each:

- Add secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- Add variable `AZURE_LOCATION` (optional, defaults to `eastus`)
- Add **required reviewers** on `STG`/`PROD` for approval gates

### 4.3 Pipeline stages

| Stage | Trigger | Action |
|---|---|---|
| `validate` | PR to `main`, manual dispatch | Ensures the resource group exists (`az group create`, idempotent), then `az deployment sub validate` across DEV/STG/PROD matrix |
| `whatif` | PR to `main` | Ensures the resource group exists, then What-If analysis, posted as PR comment + uploaded artifact |
| `deploy-dev` → `deploy-stg` → `deploy-prod` | Push to `main` | Ensures the resource group exists, then sequential deploy with GitHub Environment approval gates |
| `deploy-manual` | `workflow_dispatch` | Ensures the resource group exists (in the overridden region, if `region` input is set), then on-demand deploy to a chosen environment (`DEV`/`STG`/`PROD`/`PROD-SECONDARY-REGION`) |

Every job resolves `resourceGroupName` and `location` directly from the target environment's
`.bicepparam` file and runs `az group create --name <rg> --location <loc>` before validating or
deploying — `main.bicep` itself never creates a resource group (see §3.1a).

### 4.4 Trigger a manual deployment

GitHub UI: **Actions → Deploy Microsoft Foundry → Run workflow** → choose `environment` (and optionally `region` to override the default location, e.g. `westus2`).

CLI:
```powershell
gh workflow run deploy-foundry.yml -f environment=PROD -f region=westus2
```

## 5. Onboarding a New Model

1. Confirm availability: `az cognitiveservices model list --location <region>`.
2. Add an entry to `foundryModelDeployments` in the target environment's `.bicepparam` file (see `docs/architecture.md` §5 for the schema).
3. Open a PR — the `validate`/`whatif` stages confirm the change deploys cleanly and show the What-If diff (a single new deployment resource, no other changes).
4. Merge to trigger the standard `deploy-dev → deploy-stg → deploy-prod` pipeline, or use `deploy-manual` for an out-of-band rollout.

## 6. Deploying a New Region

1. Copy `infra/prod-secondary-region.main.bicepparam` to a new file (e.g., `infra/prod-<region>.main.bicepparam`).
2. Update `location`, `resourceGroupName`, and all globally-unique resource names (`namePrefix` ≤ 10 chars, `kvName`, `storageName`, `cosmosDBName`, `aiSearchName` if Standard Agent Setup).
3. Validate and What-If as in §3.2, then deploy via `az deployment sub create` or `deploy-manual` with the `region` input.
4. Add the new `.bicepparam` filename to the pipeline if you want it included in the automated `validate`/`whatif` matrix (edit the `matrix.environment` list in `deploy-foundry.yml`).
5. Configure your API gateway / Front Door / Traffic Manager to route to the new region's `foundryEndpoint` output — this framework does not manage cross-region traffic steering (see `docs/architecture.md` §6).

## 7. Enabling Entra ID / Apigee Gateway Integration

1. Ensure the deploying identity has the **Application Administrator** or **Cloud Application Administrator** Entra ID directory role.
2. Set `deployApigeeIntegration = true` and `apigeeGatewayAppDisplayName` in the target environment's `.bicepparam` file.
3. Deploy — this creates an Entra ID App Registration + Service Principal and grants it the **Cognitive Services OpenAI User** role on the Foundry resource.
4. Retrieve the `apigeeGatewayAppId` output; generate a client secret or certificate for it out-of-band (**not** stored in Bicep/ARM state):
   ```powershell
   az ad app credential reset --id <apigeeGatewayAppId> --display-name "apigee-gateway-secret" --years 1
   ```
5. Configure Apigee's OAuth2 client-credentials policy with the tenant ID, `apigeeGatewayAppId`, and the secret from step 4, targeting `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`.
6. Configure Apigee's target endpoint to forward the resulting bearer token to the `foundryEndpoint` output.

## 8. Troubleshooting

| Symptom | Resolution |
|---|---|
| `Name already taken` | Foundry/Key Vault/Storage/Cosmos DB/AI Search names are globally unique — choose a new suffix. |
| Role assignment failures | `deployRoleAssignments` requires Owner/User Access Administrator on the target scope. Set to `false` and assign roles manually if you lack that permission. |
| Soft-deleted Key Vault conflict | `az keyvault purge --name <name>` or choose a new name (Standard Agent Setup only). |
| Apigee module fails with permission error | The deploying principal lacks an Entra ID directory role (Azure RBAC alone is insufficient for Graph resource writes). |
| What-If shows unexpected changes | Confirm `deployRoleAssignments`/`agentSetupType`/`deployApigeeIntegration` values match what's already deployed. |
| `AADSTS700213: No matching federated identity record found for presented assertion subject 'repo:<owner>/<repo>:environment:<ENV>'` | The App Registration has no federated credential matching the **environment-scoped** subject used by these workflows. Create one with `subject` exactly `repo:<owner>/<repo>:environment:<ENV>` (case-sensitive, `<ENV>` is the GitHub Environment name: `DEV`/`STG`/`PROD`/`PROD-SECONDARY-REGION`), `issuer` `https://token.actions.githubusercontent.com`, and `audiences` `["api://AzureADTokenExchange"]` (§4.1). Also confirm `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` are set on that same GitHub Environment, so the token is validated against the app that owns the credential. |
| Workflow fails on `Verify Azure OIDC configuration` | One or more of `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` is missing from the GitHub Environment. Add them under *Settings > Environments > `<ENV>` > Environment secrets* (§4.2). |
| Model deployment fails with capacity/quota error | Check regional quota (`az cognitiveservices usage list --location <region>`) and request a quota increase if needed. |
