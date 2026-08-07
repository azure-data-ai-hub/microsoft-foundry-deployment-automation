# Demo Runbook — Model Add & Delete Lifecycle

**Environment:** DEV (`devmfdfoundry001` / `dev-mfd-foundry-rg` / eastus)
**Demo model:** `gpt-4o-mini` v`2024-07-18`, GlobalStandard, capacity 10
**Total runtime:** ~15 min (4 pipeline runs, ~2 min each + talk time)

> Demonstrates the model lifecycle described in
> [`deployment-guide.md`](deployment-guide.md) §5 (onboarding) and §5.1 (retirement).
> Values below match `infra/dev.main.bicepparam` as of writing — re-run the
> pre-flight check to confirm the baseline before demoing.

---

## Pre-flight (do this BEFORE the customer joins)

```powershell
git pull

# Confirm baseline: should list exactly 7 models, no gpt-4o-mini
az cognitiveservices account deployment list `
  --name devmfdfoundry001 --resource-group dev-mfd-foundry-rg `
  --query "[].name" -o tsv
```

Expected: `gpt-4o`, `gpt-5.5`, `gpt-5.4`, `gpt-chat-latest`, `gpt-5-nano`,
`text-embedding-ada-002`, `gpt-5-mini`

Have open in tabs:
1. `infra/dev.main.bicepparam` in VS Code
2. GitHub Actions tab
3. Azure Portal → `devmfdfoundry001` → Model deployments

---

## Scenario 1 — Baseline (2 min)

**Talking point:** *"The parameter file is the single source of truth. Let's prove
Azure currently matches it."*

Run the workflow with no changes:

```powershell
gh workflow run deploy-foundry.yml -f environment=DEV
```

**Show in the log:**
- `Show deployment summary` → "7 Foundry model deployment(s)"
- `Reconcile model deployments` → desired vs actual lists, then
  **"No orphaned model deployments - Azure matches the parameter file."**
- Job summary → **"Model deployments in sync ✅"**

---

## Scenario 2 — Add a model (4 min)

**Talking point:** *"Onboarding a model is a 4-line change. No portal clicks,
no scripts — it's reviewable, versioned infrastructure."*

### Step 2a — Edit `infra/dev.main.bicepparam`

Insert this block just before the closing `]` of `foundryModelDeployments`
(after the `text-embedding-ada-002` entry, ~line 162):

```bicep
  {
    // DEMO: small, fast, low-cost model for high-volume tasks
    name: 'gpt-4o-mini'
    model: {
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
```

### Step 2b — Commit and deploy

```powershell
git add infra/dev.main.bicepparam
git commit -m "Demo: add gpt-4o-mini to DEV"
git push
gh workflow run deploy-foundry.yml -f environment=DEV
```

**Show in the log:**
- `Show deployment summary` → now **"8 Foundry model deployment(s)"**
- `List deployed resources` → `gpt-4o-mini` with state `Succeeded`
- `Reconcile model deployments` → still **in sync** (8 desired, 8 actual)

**Show in the portal:** refresh Model deployments → `gpt-4o-mini` is live.

> **Key point to land:** the other 7 deployments were untouched. ARM Incremental
> mode is additive — no downtime, no redeploy of existing models.

---

## Scenario 3 — Delete, Part A: detection only (4 min)

**Talking point:** *"Now the interesting half. Watch what happens when I REMOVE
the model — and notice what does NOT happen."*

### Step 3a — Revert the edit

```powershell
git revert --no-edit HEAD
git push
```

(Or manually delete the block and commit — the revert is faster and shows
a clean audit trail.)

### Step 3b — Deploy normally

```powershell
gh workflow run deploy-foundry.yml -f environment=DEV
```

**Show in the log:**
- `Show deployment summary` → back to "7 Foundry model deployment(s)" and
  **"Orphaned model deployments: report only"**
- `Reconcile model deployments` → desired has 7, actual still has 8
- ⚠️ **`##[warning] Orphaned model deployment 'gpt-4o-mini' exists in Azure
  but is not in ./infra/dev.main.bicepparam`** — with the exact `az` delete
  command inline
- Job summary → "1 orphaned model deployment(s) detected ⚠️"

**Show in the portal:** `gpt-4o-mini` is **STILL THERE**.

> **Key point to land:** This is deliberate, not a bug. ARM Incremental mode
> never deletes de-referenced resources. We surface the drift loudly but refuse
> to act on it, because deleting a deployment is instantly breaking — any app
> calling that name gets a 404 with no grace period and no undo.
>
> **Why not ARM Complete mode?** This is a *subscription-scoped* deployment.
> Complete mode would delete every resource group in the subscription that
> isn't in the template. Far too blunt.

---

## Scenario 4 — Delete, Part B: opt-in prune (3 min)

**Talking point:** *"Deletion is a separate, explicit, auditable decision —
made by a human, gated by environment approvals."*

### Step 4a — Re-run with pruning enabled

**Do this in the GitHub UI** so the customer sees the checkbox:
Actions → Deploy Microsoft Foundry → Run workflow →
✅ **pruneOrphanedModels**

Or via CLI:
```powershell
gh workflow run deploy-foundry.yml -f environment=DEV -f pruneOrphanedModels=true
```

**Show in the log:**
- `Show deployment summary` → **"Orphaned model deployments: WILL BE DELETED
  (pruneOrphanedModels = true)"** — flagged *before* the deploy even runs
- `Reconcile model deployments` → **"Deleting orphaned model deployment
  'gpt-4o-mini'... Deleted 'gpt-4o-mini'."**
- Job summary → "Pruned 1 orphaned model deployment(s) 🗑️"

### Step 4b — Confirm

```powershell
az cognitiveservices account deployment list `
  --name devmfdfoundry001 --resource-group dev-mfd-foundry-rg `
  --query "[].name" -o tsv
```

Back to 7. **Show in the portal:** `gpt-4o-mini` is gone.

> **Key point to land:** On STG/PROD this same run also passes through the
> GitHub Environment approval gate — so a destructive prune needs a reviewer
> sign-off, not just a checkbox.

---

## Closing summary slide (verbal)

| Operation | Mechanism | Safety |
|---|---|---|
| **Add** | Declarative — edit `.bicepparam`, deploy | Additive; existing models untouched |
| **Detect drift** | Automatic on every deploy | Read-only, zero risk |
| **Delete** | Opt-in `pruneOrphanedModels` input | Explicit + approval-gated |

**The quota angle (good closer):** orphaned deployments aren't free — each one
holds its `sku.capacity` against the subscription's regional TPM quota. Left
unreconciled, they cause quota failures on *unrelated* future deployments.
That's why continuous drift detection matters, not just cleanup-on-demand.

---

## Recovery / if something goes wrong

**Deploy fails on quota** — pick a smaller `capacity` (e.g. 1) or switch the
demo model to `text-embedding-3-small` (v1, Standard).

**Need to hard-reset DEV to baseline:**
```powershell
az cognitiveservices account deployment delete `
  --name devmfdfoundry001 --resource-group dev-mfd-foundry-rg `
  --deployment-name gpt-4o-mini
git log --oneline -3   # revert any demo commits still on main
```

**Pipeline run is slow / stuck** — deploys take ~90-120s. Watch with:
```powershell
gh run watch (gh run list --workflow=deploy-foundry.yml --limit 1 --json databaseId --jq ".[0].databaseId") --exit-status
```
