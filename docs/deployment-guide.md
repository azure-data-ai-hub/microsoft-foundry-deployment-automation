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
├── dev.main.bicepparam                 # Dev, minimal (Basic Agent Setup, Foundry-only)
├── dev-standard.main.bicepparam        # Dev, full BYO-storage (Standard Agent Setup)
├── stg.main.bicepparam                 # Staging (Basic Agent Setup)
├── prod.main.bicepparam                # Production, eastus (Standard Agent Setup)
└── prod-secondary-region.main.bicepparam  # Production, westus2 (multi-region example)
azure.yaml                              # azd project config
.github/workflows/deploy-foundry.yml    # CI/CD pipeline
.github/workflows/evaluate-models.yml   # On-demand model quality evaluation
scripts/
├── validate-inference.py               # Post-deployment inference smoke test
└── run-evaluations.py                  # Graded model quality evaluation (Evals API)
evaluations/
├── models.json                         # Per-model datasets, thresholds, prompts
├── default.jsonl                       # Fallback dataset
└── <deployment>.jsonl                  # Per-model expected answers (e.g. gpt-4o.jsonl)
docs/                                   # This documentation set
├── architecture.md
├── deployment-guide.md                 # This document
├── model-lifecycle-demo.md             # Scripted model add/delete walkthrough
├── operational-handoff.md
└── knowledge-transfer.md
```

## 3. Step-by-Step: First-Time Deployment

### 3.1 Clone and customize parameters

1. Clone the repository.
2. Open `infra/dev.main.bicepparam` (and `stg`/`prod` as needed) and set **globally unique** names:
   - `namePrefix` (max 10 characters)
   - If using Standard Agent Setup: use `infra/dev-standard.main.bicepparam` instead (or `stg`/`prod`, which are already Standard) and set `kvName`, `storageName`, `cosmosDBName`, `aiSearchName`
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

> `DEV-STANDARD` (the `workflow_dispatch` option that deploys `infra/dev-standard.main.bicepparam`)
> reuses the `DEV` GitHub Environment's secrets and federated credential automatically — no
> separate GitHub Environment or federated credential subject is needed. `deploy-foundry.yml`
> maps the `DEV-STANDARD` input to the `DEV` GitHub Environment (`environment.name` in the
> `deploy-manual` job) while still selecting `dev-standard.main.bicepparam` for the actual
> deployment based on the raw input value.

### 4.3 Pipeline stages

| Stage | Trigger | Action |
|---|---|---|
| `validate` | PR to `main`, push to `main` | Ensures the resource group exists (`az group create`, idempotent), then `az deployment sub validate` across the DEV and DEV-STANDARD matrix entries (both authenticate via the `DEV` GitHub Environment) |
| `deploy-manual` | `workflow_dispatch` | Ensures the resource group exists (in the overridden region, if `region` input is set), then on-demand deploy to a chosen environment (`DEV`/`DEV-STANDARD`/`STG`/`PROD`/`PROD-SECONDARY-REGION`). The `.bicepparam` file is selected from the raw input (`infra/<lowercased-input>.main.bicepparam`), but the GitHub Environment used for secrets/OIDC is `DEV` for both `DEV` and `DEV-STANDARD`. After a successful deploy it reconciles model deployments (see §5.1), then validates that every deployed model actually serves inference (see §4.3a) |
| `evaluate` | `workflow_dispatch` (separate workflow, `evaluate-models.yml`) | Runs a graded question/answer dataset against every chat deployment on the target environment and fails if accuracy drops below the pass threshold (see §4.3b) |

This is intentionally a simple two-stage pipeline: `validate` gives fast feedback on every PR/push,
and all actual deployments go through the explicit, auditable `deploy-manual` on-demand trigger
(GitHub Environment approval gates on `STG`/`PROD` still apply). There is no automatic
push-to-deploy chain and no What-If stage.

Every job resolves `resourceGroupName` and `location` directly from the target environment's
`.bicepparam` file and runs `az group create --name <rg> --location <loc>` before validating or
deploying — `main.bicep` itself never creates a resource group (see §3.1a).

### 4.3a Post-deployment inference validation

A successful ARM deployment only proves each model deployment resource reached
`provisioningState = Succeeded`. It does not prove the model actually serves traffic — regional
capacity can be unavailable, and AAD data-plane role assignments may still be propagating.

After a successful deploy, `deploy-manual` runs `scripts/validate-inference.py`, which sends a real
request to every deployment on the account and fails the run if any model does not respond. It is a
stdlib-only Python script, so the runner needs no `pip install`.

| Deployment kind | Probe |
|---|---|
| Chat / completion models | `POST /openai/deployments/<name>/chat/completions` |
| Embedding models | `POST /openai/deployments/<name>/embeddings` |
| `GlobalBatch` SKU | Skipped — serves the asynchronous Batch API only, so a synchronous call always fails |
| Anything else | Skipped |

Set the **runInferenceValidation** dispatch input to `false` to skip the step.

Two behaviours worth knowing before you read a failure:

- **Batch deployments still advertise `chatCompletion: true`** in their capability flags, so the
  script dispatches on the SKU *before* the capabilities. Trusting the flags alone would produce a
  guaranteed false failure.
- **Reasoning models spend their token budget on hidden reasoning tokens.** With too small a budget
  they return empty content and `finish_reason=length`, which looks like a failure but is not. The
  default `--max-completion-tokens 256` leaves enough headroom; the failure message says so if you
  lower it.

Run it locally against any environment:

```bash
python3 scripts/validate-inference.py \
  --foundry-name devmfdfoundry001 \
  --resource-group dev-mfd-foundry-rg
```

Exit codes: `0` all passed, `1` at least one model failed, `2` could not run at all (bad account,
no token, unknown deployment name). Add `--deployment <name>` (repeatable) to probe a subset.

**Required permission:** inference is a *data-plane* action. The control-plane roles a deploy
identity normally holds — Contributor, Owner, User Access Administrator — carry no `dataActions` and
therefore do **not** grant it. The caller needs **Cognitive Services OpenAI User** on the Foundry
account. The pipeline handles this automatically: it resolves its own object ID and passes it as
`inferenceValidationPrincipalId`, and `main.bicep` creates the assignment. To grant it by hand:

```bash
az role assignment create \
  --assignee <objectId> \
  --role "Cognitive Services OpenAI User" \
  --scope $(az cognitiveservices account show -n <foundry> -g <rg> --query id -o tsv)
```

### 4.3b Model quality evaluations

Inference validation (§4.3a) proves a deployment **responds**. It cannot tell you whether the model
is still **correct**. A deployment re-pointed at a newer model version, or one silently routed
elsewhere, will return a fluent-but-wrong answer and pass a smoke test unchanged.

The **Evaluate Models** workflow (`.github/workflows/evaluate-models.yml`) closes that gap. It runs a
graded question/answer dataset through the Azure OpenAI Evals API
(`{endpoint}/openai/v1/evals`) and fails when accuracy drops below a threshold.

It is a separate, dispatch-only workflow rather than a step in the deploy pipeline, because it takes
minutes rather than seconds and is usually run against an already-deployed environment.

**Trigger:** *Actions → Evaluate Models → Run workflow*, or:

```powershell
gh workflow run evaluate-models.yml -f environment=DEV
gh workflow run evaluate-models.yml -f environment=DEV -f deployments="gpt-4o gpt-5-mini" -f passThreshold=1.0
```

**Grading.** Every item is scored by two deterministic criteria, and must pass **both**:

| Criterion | Purpose |
|---|---|
| `string_check` (`ilike`) | Catches gross breakage — the expected answer is absent entirely. |
| `text_similarity` (`fuzzy_match` ≥ 0.6) | Tolerates trailing punctuation, capitalisation, and minor wording drift. |

Deterministic graders are chosen over an LLM judge because they are reproducible, add no second
model as a dependency, and cost nothing extra to run.

A deployment passes when at least `passThreshold` (default `0.8`) of the dataset items pass.
`GlobalBatch` and embedding deployments are skipped automatically, as neither serves synchronous
question/answer traffic.

**Per-model datasets.** Models word correct answers differently, so each deployment is graded
against its own expected answers rather than one shared file. With loosely-worded instructions
`gpt-4o` answers `11, 13, 17` where every other deployment answers `11,13,17`; under the `ilike`
substring grader that is a real pass/fail difference, and a shared dataset would report a false
failure for whichever model did not match.

Resolution order for a deployment, highest priority first:

1. an explicit `--dataset` on the command line — applies to every deployment, which keeps ad-hoc and
   negative-control runs predictable
2. the deployment's `dataset` entry in `evaluations/models.json`
3. `evaluations/<deployment>.jsonl`, if that file exists
4. the manifest's `default` block
5. `--default-dataset` (`evaluations/default.jsonl`)

`evaluations/models.json` additionally supports per-model `passThreshold`, `systemPrompt`,
`similarityThreshold` and `similarityMetric`. A deployment only needs an entry when it differs from
the defaults, since per-model files already resolve by convention. `similarityThreshold` and
`similarityMetric` belong to the evaluation definition rather than the run, so deployments differing
on either automatically get their own evaluation created.

`model-router` is the one deployment with a manifest entry today: it forwards each request to
whichever underlying model it judges best, so its answering model can change between runs with no
change to this repository. It is given a slightly lower threshold so routing churn alone does not
fail the pipeline.

**Rate limiting.** A throttled item returns no content, which naive grading scores as a wrong
answer — reporting a capacity problem as a quality regression. HTTP 429 is therefore detected in the
run's `output_items`, retried (`--max-run-retries`, default 2), and if it persists reported
explicitly as a TPM quota problem rather than a model failure.

**Token budget.** Reasoning models spend hidden tokens before emitting text, so a small budget
yields empty answers. `--max-completions-tokens` (default 2000) sets the per-item budget. Note the
plural — the Evals API spells this `max_completions_tokens`, unlike the chat completions API's
`max_completion_tokens`.

Run it locally:

```bash
python3 scripts/run-evaluations.py \
  --foundry-name devmfdfoundry001 \
  --resource-group dev-mfd-foundry-rg
```

Exit codes match `validate-inference.py`: `0` all passed, `1` at least one deployment fell below the
threshold, `2` could not run at all. Useful flags: `--deployment <name>` (repeatable),
`--pass-threshold`, `--similarity-threshold`, `--similarity-metric` (`fuzzy_match`, `bleu`,
`rouge_l`, `meteor`), `--dataset`, `--default-dataset`, `--manifest`, `--max-completions-tokens`,
`--max-run-retries`, `--keep-eval`.

**Cleanup.** Evaluation definitions are created per distinct grading configuration and deleted in a
`finally` block, so cancelled runs still clean up. `--keep-eval` retains them for inspection in the
Azure AI Foundry portal.

**Required permission:** the same **Cognitive Services OpenAI User** data-plane role described in
§4.3a. Because that role is granted by `main.bicep` during a deploy, deploy an environment at least
once before evaluating it.

**Writing dataset items.** Each `.jsonl` holds one JSON object per line with `question`, `answer`,
and `category`; lines beginning `//` are treated as comments. Prefer questions whose correct answer
has a single unambiguous surface form, and phrase them to force a terse reply ("Reply with only the
city name").

Fix an ambiguous question in preference to encoding a model quirk per model. Tightening "separated
by commas" to "separated by commas, with no spaces" made all seven deployments answer identically
and eliminated an item that had been intermittently failing `gpt-5.5`. Similarly, "the chemical
symbol for water" was removed because `gpt-4o` answers `H₂O` with a Unicode subscript — correct, but
failing an exact-match grader. False alarms cost more than a slightly smaller dataset.

### 4.4 Trigger a manual deployment

GitHub UI: **Actions → Deploy Microsoft Foundry → Run workflow** → choose `environment` (and optionally `region` to override the default location, e.g. `westus2`, and `pruneOrphanedModels` to delete de-referenced model deployments — see §5.1).

CLI:
```powershell
gh workflow run deploy-foundry.yml -f environment=PROD -f region=westus2
```

## 5. Onboarding a New Model

1. Confirm availability: `az cognitiveservices model list --location <region>`.
2. Add an entry to `foundryModelDeployments` in the target environment's `.bicepparam` file (see `docs/architecture.md` §5 for the schema).
3. Open a PR — the `validate` stage confirms the change deploys cleanly (`az deployment sub validate`) for DEV and DEV-STANDARD. Changes to `stg`/`prod` parameter files are **not** validated automatically (see §4.3).
4. Use `deploy-manual` (Actions → Run workflow) to roll out the change to the desired environment(s) in order (DEV → STG → PROD). The run ends by probing every deployed model, so a model that provisions but cannot serve traffic fails the run rather than passing silently (see §4.3a).

Adding a model is purely additive: the deployment runs in ARM **Incremental** mode, so the new
entry is created and every existing deployment is left untouched.

### 5.1 Retiring a Model

Removing an entry from `foundryModelDeployments` does **not** delete it from Azure. Incremental
mode only creates and updates the resources present in the template — it never deletes resources
that were removed from it. (ARM `Complete` mode would, but it is unusable here: this is a
subscription-scoped deployment, so Complete mode would delete every resource in scope that isn't
in the template, including resource groups.)

The pipeline handles this with a **Reconcile model deployments** step that runs after every
successful `deploy-manual` run. It compiles the `.bicepparam` to JSON (`az bicep build-params`),
diffs the desired deployment names against `az cognitiveservices account deployment list`, and:

- **By default** (`pruneOrphanedModels` unchecked) it only *reports* orphans — one
  `::warning::` per orphan plus a job-summary block with the exact `az` delete command. Nothing
  is deleted, so a routine deploy can never remove a model by accident.
- **When `pruneOrphanedModels` is checked** it deletes each orphan with
  `az cognitiveservices account deployment delete`. Because this is a `workflow_dispatch` input,
  deletion is always an explicit, auditable, human-triggered decision — and on `STG`/`PROD` it
  still passes through the GitHub Environment approval gate.

Deleting a model deployment is **immediately breaking**: any application calling that deployment
name starts receiving `404 DeploymentNotFound` as soon as the delete completes. There is no
grace period and no undo — recreating it is a new deployment that must re-acquire quota.
Recommended retirement sequence:

1. Repoint application code/config to the replacement deployment name and release it.
2. Confirm zero traffic to the old deployment (Azure Monitor metrics on the Foundry account,
   split by deployment name).
3. Remove the entry from the `.bicepparam` file and merge.
4. Run `deploy-manual` normally — confirm the warning lists exactly the deployment(s) you expect.
5. Re-run `deploy-manual` with `pruneOrphanedModels` checked to delete them.

Orphans are not free: each one continues to hold its `sku.capacity` allocation against the
subscription's regional TPM quota, which can cause later deployments to fail with quota errors
even though the model is unused. Reconcile regularly rather than letting drift accumulate.

To delete a deployment manually instead:
```powershell
az cognitiveservices account deployment delete `
  --name <foundryName> --resource-group <rg> --deployment-name <deploymentName>
```

For a scripted walkthrough of both the add and delete flows (useful for demos and
onboarding), see [`model-lifecycle-demo.md`](model-lifecycle-demo.md).

## 6. Deploying a New Region

1. Copy `infra/prod-secondary-region.main.bicepparam` to a new file (e.g., `infra/prod-<region>.main.bicepparam`).
2. Update `location`, `resourceGroupName`, and all globally-unique resource names (`namePrefix` ≤ 10 chars, `kvName`, `storageName`, `cosmosDBName`, `aiSearchName` if Standard Agent Setup).
3. Validate as in §3.2, then deploy via `az deployment sub create` or `deploy-manual` with the `region` input.
4. Add the new `.bicepparam` filename to the pipeline if you want it included in the automated `validate` matrix (add an entry to the `matrix.include` list in `deploy-foundry.yml`, with `name` matching the parameter filename and `githubEnvironment` set to a GitHub Environment that has a federated credential).
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
| `az deployment sub validate` shows unexpected changes | Confirm `deployRoleAssignments`/`agentSetupType`/`deployApigeeIntegration` values match what's already deployed. |
| Cosmos DB creation fails with `ServiceUnavailable`/high-demand error (Standard Agent Setup only) | Transient regional capacity shortage for new Cosmos DB accounts (independent of the `isZoneRedundant: false` setting already used by `modules/cosmosdb.bicep`). First, check for a stuck account left by the failed attempt (`az cosmosdb show --name <name> --resource-group <rg>` — if `provisioningState` is `Failed`, delete it with `az cosmosdb delete` before retrying, otherwise redeploy fails with `BadRequest`/"previous attempt to create it was not successful"). Then either retry later, or set the `cosmosDBLocation` parameter to a nearby region with available capacity (Cosmos DB connects to the Foundry project cross-region without issue) — see `dev.main.bicepparam` for an example. |
| Model deployment fails with capacity/quota error | Check regional quota (`az cognitiveservices usage list --location <region>`) and request a quota increase if needed. Also check for orphaned deployments still holding quota (see next row). |
| Model removed from `.bicepparam` still exists in Azure | Expected — ARM Incremental mode never deletes de-referenced resources. The pipeline's **Reconcile model deployments** step reports these as warnings; re-run `deploy-manual` with `pruneOrphanedModels` checked to delete them. See §5.1. |
| `validate` job fails at "Azure Login (OIDC)" with `AADSTS700213` for an environment | That GitHub Environment has no matching federated identity credential. The `validate` matrix is intentionally limited to environments that do (see §4.3) — don't add an entry to `matrix.include` until the credential exists, or the gated build fails on authentication rather than on any template problem. Note the failure is unrelated to the Bicep: check whether the `Validate Bicep - DEV` job passed to confirm. |
| Inference validation fails with HTTP 401/403 for every model | The calling identity has no data-plane role. Inference is a `dataAction`, and Contributor/Owner/User Access Administrator grant none — control-plane access is not enough. Assign **Cognitive Services OpenAI User** on the Foundry account (see §4.3a). In the pipeline this is automatic; if the "Resolve inference validation principal" step logged a warning, it could not determine the object ID and skipped the grant. |
| Inference validation reports `empty content (finish_reason=length)` | A reasoning model consumed the whole token budget on hidden reasoning tokens before emitting any text. Raise `--max-completion-tokens` (default 256). Not an outage. |
| Inference validation fails only for a `GlobalBatch` deployment | It should be skipped, not failed — batch deployments serve the asynchronous Batch API and reject synchronous calls. If it is being probed, the deployment's SKU is not reporting as `GlobalBatch`; check `az cognitiveservices account deployment show --deployment-name <name>`. |
| Inference validation fails for one model while others pass | Model-specific: check regional capacity for that SKU and confirm the deployment's `provisioningState` is `Succeeded`. Re-run with `--deployment <name>` to iterate quickly without probing the whole account. |
| Evaluation run shows `status: completed` but the workflow failed | Working as intended, and an important distinction. An Evals run reports `completed` whenever it finishes executing — *even if every single assertion failed*. `completed` describes the run's lifecycle, not the outcome. `run-evaluations.py` therefore gates on `result_counts` (`passed`/`failed`/`errored`), never on `status`. Gating on `status` would produce a check that passes no matter how badly the model performs. |
| A model fails evaluation but passes inference validation | Expected, and exactly what this workflow exists to catch. Inference validation only proves the endpoint responded; evaluation proves the answers are still correct. Most commonly the deployment was re-pointed at a new model version whose output formatting changed. Re-run with `keepEval` enabled and inspect the per-item results in the Azure AI Foundry portal before assuming the model is degraded. |
| Evaluation fails on an answer that looks correct | The grader is an exact/fuzzy string match, not a judge. Unicode variants are the usual culprit — `H₂O` vs `H2O`, curly vs straight quotes, `—` vs `-`. Separator spacing is another: `gpt-4o` writes `11, 13, 17` where other models write `11,13,17`. Fix the question (make the required format explicit) or, if the model is genuinely and repeatably different, update that model's `evaluations/<deployment>.jsonl`. Do not lower `--pass-threshold` to hide it — that also hides real regressions. |
| Evaluation reports `rate limited (HTTP 429)` | A capacity problem, not a quality problem. Throttled items return no content and would otherwise be graded as wrong answers, so 429 is detected and the run retried (`--max-run-retries`, default 2). If it persists the deployment needs more TPM quota — check `az cognitiveservices usage list --location <region>`. Evaluating a single deployment at a time with `--deployment` also reduces pressure. |
| A model intermittently fails one item | Check whether the answers are empty: that is throttling or too small a token budget, not a wrong expected answer. Raise `--max-completions-tokens` (default 2000) for reasoning models. If the answer is present but varies in format between runs, the question is ambiguous — tighten its wording rather than encoding one variant. |
| Evaluation items report `errored` rather than `failed` | `errored` means the item never reached a grader, so it is not a model-quality signal — treat it as an infrastructure fault. Check the run's `output_items` for the per-item error; the run-level message (`All examples failed due to invalid user input`) is deliberately vague and rarely identifies the cause. |
| Evaluation times out | Each deployment's run is polled up to `--run-timeout` (default 900s); a full sweep of ~7 chat deployments against an 8-item dataset takes roughly 3-4 minutes. A single run exceeding the timeout usually means the deployment has no available capacity — confirm with `scripts/validate-inference.py --deployment <name>` first, since that fails in seconds. |
| Evaluation fails with `'response_format' of type 'json_schema' is not supported with this model` | Only applies if the script is modified to use an LLM (`score_model`) grader. Judge models must support structured outputs; `gpt-4o` pinned at `2024-05-13` predates that support. Use a newer judge deployment, or stay with the default deterministic graders, which have no such constraint. |
