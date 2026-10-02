#!/usr/bin/env python3
"""Run Microsoft Foundry model evaluations as a deployment gate.

Where scripts/validate-inference.py answers "does the endpoint respond?", this
answers "does the model still produce correct answers?". It drives the Azure
OpenAI Evals API: an evaluation defines a dataset schema plus grading criteria,
and a run executes that evaluation against one model deployment.

Graders here are deliberately deterministic (string_check / text_similarity):
they cost nothing, never flake, and give a stable pass/fail signal suitable for
gating a pipeline. LLM-as-judge graders (score_model) are supported by the API
but are not used, because their scores vary between runs and would make the
gate nondeterministic. Note also that a judge grader requires a grader model
supporting structured outputs -- gpt-4o pinned at 2024-05-13 does not, and
fails with "'response_format' of type 'json_schema' is not supported".

Each deployment is graded against its own dataset, because models word correct
answers differently: with loose phrasing gpt-4o replies "11, 13, 17" where
other deployments reply "11,13,17". See resolve_plan() for the lookup order.

Authentication is Microsoft Entra ID only, matching the Foundry resource's
disableLocalAuth: true.

Uses only the Python standard library so it runs on a stock GitHub-hosted
runner with no pip install step.

Examples:
    python3 scripts/run-evaluations.py \
        --foundry-name devmfdfoundry001 --resource-group dev-mfd-foundry-rg

    # Evaluate a single deployment and keep the eval for inspection
    python3 scripts/run-evaluations.py \
        --foundry-name devmfdfoundry001 --resource-group dev-mfd-foundry-rg \
        --deployment gpt-4o --keep-eval

Exit codes:
    0  every evaluated model met the pass threshold
    1  at least one model fell below the threshold, or a run errored
    2  the run could not produce a verdict: login, endpoint lookup, bad dataset,
       or a deployment that stayed rate limited (a capacity fault, not a model
       quality failure)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

TOKEN_SCOPE = "https://cognitiveservices.azure.com"

# Batch deployments accept work only through the asynchronous /batches API, so
# an evaluation run against them cannot complete synchronously.
BATCH_SKU_MARKER = "batch"

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"

# Rate limiting is a capacity fault, not a wrong answer. It gets its own status
# so it exits 2 (infrastructure) rather than 1 (model quality) and nobody goes
# hunting a model regression that does not exist.
BLOCKED = "BLOCKED"

# Terminal states reported by the Evals API for a run.
TERMINAL_STATES = ("completed", "failed", "canceled", "cancelled")

RETRYABLE_STATUS = {429, 500, 502, 503, 504}

# 401/403 is normally deterministic, but immediately after a deployment that
# just created the caller's role assignment it is usually RBAC propagation.
AUTH_STATUS = {401, 403}
AUTH_MAX_ATTEMPTS = 4


class ModelResult(object):
    def __init__(self, name, status, detail, counts=None, elapsed=0.0, run_url=""):
        self.name = name
        self.status = status
        self.detail = detail
        self.counts = counts or {}
        self.elapsed = elapsed
        self.run_url = run_url
        self.dataset = ""


def run_az(args):
    """Invoke the Azure CLI and return stdout, or exit 2 ("could not run")."""
    az = shutil.which("az") or shutil.which("az.cmd")
    if not az:
        print("ERROR: Azure CLI ('az') not found on PATH.", file=sys.stderr)
        sys.exit(2)
    proc = subprocess.run([az] + args, capture_output=True, text=True)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout).strip()
        print("ERROR: az {} failed:\n{}".format(" ".join(args), err), file=sys.stderr)
        sys.exit(2)
    return proc.stdout.strip()


def get_token():
    """Prefer an injected token so CI can reuse the existing federated login."""
    token = os.environ.get("AZURE_INFERENCE_TOKEN", "").strip()
    if token:
        return token
    return run_az(
        ["account", "get-access-token", "--resource", TOKEN_SCOPE, "--query", "accessToken", "-o", "tsv"]
    )


def redact(text, token):
    return text.replace(token, "***") if token else text


def api(base, method, path, token, body=None, timeout=120, max_attempts=4):
    """Call the Evals API with retries. Returns (status, parsed_or_none, raw)."""
    url = base.rstrip("/") + path
    attempt = 1
    while True:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer {}".format(token))
        if data is not None:
            req.add_header("Content-Type", "application/json")

        status, raw, retry_after = 0, "", None
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.status
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read().decode("utf-8", "replace")
            retry_after = exc.headers.get("Retry-After")
        except urllib.error.URLError as exc:
            raw = "network error: {}".format(exc.reason)
        except TimeoutError:
            raw = "request timed out after {}s".format(timeout)

        if 200 <= status < 300:
            try:
                return status, json.loads(raw or "{}"), raw
            except json.JSONDecodeError:
                return status, None, raw

        transient = status in RETRYABLE_STATUS or status == 0
        if status in AUTH_STATUS and attempt < AUTH_MAX_ATTEMPTS:
            transient = True
        if not transient or attempt >= max_attempts:
            try:
                return status, json.loads(raw), raw
            except json.JSONDecodeError:
                return status, None, raw

        delay = 2 ** attempt
        if status in AUTH_STATUS:
            delay = 15
        if retry_after:
            try:
                delay = max(delay, int(retry_after))
            except ValueError:
                pass
        print("      attempt {}/{} got HTTP {}; retrying in {}s".format(
            attempt, max_attempts, status or "network error", delay))
        time.sleep(delay)
        attempt += 1


def error_message(parsed, raw):
    if isinstance(parsed, dict):
        err = parsed.get("error")
        if isinstance(err, dict) and err.get("message"):
            return str(err["message"])
        if isinstance(err, str):
            return err
    return " ".join((raw or "").split())[:300]


def http_failure(status, parsed, raw):
    detail = "HTTP {}: {}".format(status or "network error", error_message(parsed, raw))
    if status in AUTH_STATUS:
        detail += (
            " | Evaluations are a data-plane action; control-plane roles do not grant them."
            " Assign 'Cognitive Services User' to the calling identity at the Foundry account scope."
        )
    return detail


def load_dataset(path):
    """Read a JSONL dataset into the file_content shape the Evals API expects."""
    if not os.path.exists(path):
        print("ERROR: dataset not found: {}".format(path), file=sys.stderr)
        sys.exit(2)

    content = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                print("ERROR: {}:{} is not valid JSON: {}".format(path, lineno, exc), file=sys.stderr)
                sys.exit(2)
            missing = [k for k in ("question", "answer") if k not in item]
            if missing:
                print("ERROR: {}:{} missing required field(s): {}".format(
                    path, lineno, ", ".join(missing)), file=sys.stderr)
                sys.exit(2)
            content.append({"item": item})

    if not content:
        print("ERROR: dataset {} contains no usable rows.".format(path), file=sys.stderr)
        sys.exit(2)
    return content


def load_manifest(path):
    """Load the optional per-model evaluation manifest.

    Absent manifest is not an error: resolution falls back to the
    evaluations/<deployment>.jsonl convention and then the default dataset.
    """
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print("ERROR: could not read manifest {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)
    if not isinstance(manifest, dict):
        print("ERROR: manifest {} must be a JSON object.".format(path), file=sys.stderr)
        sys.exit(2)
    return manifest


def resolve_plan(deployment, args, manifest):
    """Work out which dataset and grading settings apply to one deployment.

    Models answer the same question differently -- gpt-4o replies "11, 13, 17"
    where other models reply "11,13,17" -- so a single shared dataset either has
    to avoid everything models disagree on, or it reports false failures. Each
    deployment therefore gets its own expected answers.

    Precedence, highest first:
      1. an explicit --dataset on the command line (applies to every model, so
         ad-hoc and negative-control runs stay predictable)
      2. the deployment's entry in the manifest
      3. evaluations/<deployment>.jsonl, if it exists
      4. the manifest's "default" block
      5. the built-in defaults / other command-line flags

    An explicit --pass-threshold overrides manifest thresholds.
    """
    defaults = manifest.get("default", {}) or {}
    entry = (manifest.get("deployments", {}) or {}).get(deployment, {}) or {}

    if args.dataset:
        dataset, source = args.dataset, "--dataset"
    elif entry.get("dataset"):
        dataset, source = entry["dataset"], "manifest"
    else:
        conventional = os.path.join(os.path.dirname(args.default_dataset),
                                    "{}.jsonl".format(deployment))
        if os.path.exists(conventional):
            dataset, source = conventional, "per-model file"
        else:
            dataset, source = defaults.get("dataset") or args.default_dataset, "default"

    def pick(key, cli_value):
        if key in entry:
            return entry[key]
        if key in defaults:
            return defaults[key]
        return cli_value

    return {
        "dataset": dataset,
        "dataset_source": source,
        "system_prompt": pick("systemPrompt", args.system_prompt),
        "pass_threshold": (args.pass_threshold if args.pass_threshold is not None
                           else float(pick("passThreshold", 0.8))),
        "similarity_threshold": float(pick("similarityThreshold", args.similarity_threshold)),
        "similarity_metric": pick("similarityMetric", args.similarity_metric),
    }


def classify(dep):
    """Decide whether a deployment can be evaluated.

    The SKU is checked before the capability flags on purpose: a GlobalBatch
    deployment still reports chatCompletion: true, so trusting the flags alone
    would queue a run that can never complete.
    """
    props = dep.get("properties", {}) or {}
    sku_name = (dep.get("sku", {}) or {}).get("name", "") or ""
    caps = props.get("capabilities", {}) or {}

    if BATCH_SKU_MARKER in sku_name.lower():
        return None, "{} serves the asynchronous Batch API only".format(sku_name)
    if str(caps.get("chatCompletion", "")).lower() == "true":
        return "chat", ""
    if str(caps.get("embeddings", "")).lower() == "true":
        return None, "embedding model - not applicable to question/answer evaluation"
    return None, "no chat capability advertised"


def build_eval_body(name, threshold_metric, similarity_threshold):
    """An evaluation = dataset schema + grading criteria.

    Two deterministic criteria are used together because each alone is too
    blunt: string_check catches a model that stopped answering correctly at
    all, while text_similarity tolerates harmless wording differences (for
    example "Paris." versus "Paris") that an exact check would fail on.
    """
    return {
        "name": name,
        "data_source_config": {
            "type": "custom",
            "item_schema": {
                "type": "object",
                "properties": {
                    "question": {"type": "string"},
                    "answer": {"type": "string"},
                    "category": {"type": "string"},
                },
                "required": ["question", "answer"],
            },
            "include_sample_schema": True,
        },
        "testing_criteria": [
            {
                "type": "string_check",
                "name": "contains_expected_answer",
                "input": "{{sample.output_text}}",
                "operation": "ilike",
                "reference": "{{item.answer}}",
            },
            {
                "type": "text_similarity",
                "name": "similar_to_expected",
                "input": "{{sample.output_text}}",
                "reference": "{{item.answer}}",
                "evaluation_metric": threshold_metric,
                "pass_threshold": similarity_threshold,
            },
        ],
    }


def build_run_body(deployment, content, system_prompt, max_completions_tokens):
    body = {
        "name": "{}-{}".format(deployment, int(time.time())),
        "data_source": {
            "type": "completions",
            "model": deployment,
            "input_messages": {
                "type": "template",
                "template": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": "{{item.question}}"},
                ],
            },
            "source": {"type": "file_content", "content": content},
        },
    }
    if max_completions_tokens:
        # Note the plural: the Evals API names this max_completions_tokens,
        # unlike the chat completions API's max_completion_tokens. Reasoning
        # models spend hidden tokens before emitting text, so a small budget
        # yields empty output that grades as a wrong answer.
        body["data_source"]["sampling_params"] = {
            "max_completions_tokens": max_completions_tokens,
        }
    return body


def error_causes(base, token, eval_id, run_id):
    """Summarise why items errored, so throttling isn't mistaken for bad answers.

    A rate-limited item produces no output and would otherwise be indistinguishable
    from a model that answered incorrectly.
    """
    status, parsed, _ = api(
        base, "GET", "/evals/{}/runs/{}/output_items?limit=100".format(eval_id, run_id), token)
    if status != 200 or not isinstance(parsed, dict):
        return 0, 0, ""

    throttled, other, sample = 0, 0, ""
    for item in parsed.get("data", []) or []:
        if item.get("status") == "pass":
            continue
        err = (item.get("sample", {}) or {}).get("error") or {}
        if not err:
            continue
        code = str(err.get("code", ""))
        message = str(err.get("message", ""))
        if code == "429" or "rate limit" in message.lower():
            throttled += 1
        else:
            other += 1
            sample = sample or message
    return throttled, other, sample


def poll_run(base, token, eval_id, run_id, timeout_s, interval_s):
    """Wait for a run to reach a terminal state."""
    deadline = time.time() + timeout_s
    last_state = "unknown"
    while time.time() < deadline:
        status, parsed, raw = api(base, "GET", "/evals/{}/runs/{}".format(eval_id, run_id), token)
        if status != 200 or not isinstance(parsed, dict):
            return None, http_failure(status, parsed, raw)
        last_state = parsed.get("status", "unknown")
        if last_state in TERMINAL_STATES:
            return parsed, ""
        time.sleep(interval_s)
    return None, "timed out after {}s waiting for run to finish (last state: {})".format(
        timeout_s, last_state)


def evaluate_deployment(base, token, eval_id, deployment, content, plan, args):
    """Run the dataset against one deployment, retrying transient throttling.

    Rate limiting produces items with no output. Graded naively those look
    exactly like wrong answers, so a capacity problem would be reported as a
    model quality regression and send someone hunting a nonexistent bug.
    """
    started = time.time()
    attempt = 1
    while True:
        result, retry_reason = run_once(base, token, eval_id, deployment, content, plan, args, started)
        if not retry_reason or attempt > args.max_run_retries:
            if retry_reason:
                # Out of retries: report the real cause, and mark it BLOCKED so
                # the exit code says "capacity" rather than "bad model".
                result.status = BLOCKED
                result.detail = "{} after {} attempt(s)".format(retry_reason, attempt)
            return result
        # TPM quota refills on a rolling per-minute window, so back off further
        # each attempt: a flat short delay can land inside the same exhausted
        # window and burn a retry for nothing.
        delay = args.retry_delay * attempt
        print("     {} - retrying run in {}s ({}/{})".format(
            retry_reason, delay, attempt, args.max_run_retries))
        time.sleep(delay)
        attempt += 1


def run_once(base, token, eval_id, deployment, content, plan, args, started):
    """Execute one run. Returns (result, retry_reason); retry_reason is '' when final."""
    status, parsed, raw = api(
        base, "POST", "/evals/{}/runs".format(eval_id), token,
        body=build_run_body(deployment, content, plan["system_prompt"],
                            args.max_completions_tokens))
    if status not in (200, 201) or not isinstance(parsed, dict):
        return (ModelResult(deployment, FAIL, "could not start run: " + http_failure(status, parsed, raw),
                            elapsed=time.time() - started), "")

    run_id = parsed.get("id", "")
    run_url = parsed.get("report_url", "") or ""
    run, err = poll_run(base, token, eval_id, run_id, args.run_timeout, args.poll_interval)
    elapsed = time.time() - started
    if run is None:
        return ModelResult(deployment, FAIL, err, elapsed=elapsed, run_url=run_url), ""

    counts = run.get("result_counts", {}) or {}
    total = counts.get("total", 0) or 0
    passed = counts.get("passed", 0) or 0
    failed = counts.get("failed", 0) or 0
    errored = counts.get("errored", 0) or 0
    run_url = run.get("report_url", "") or run_url

    if total == 0:
        return (ModelResult(deployment, FAIL, "run produced no graded results",
                            counts, elapsed, run_url), "")

    if errored:
        # An errored item never reached a grader, so it is not a quality signal.
        # Throttling is the common cause and is transient, so ask for a retry
        # instead of reporting the model as broken.
        throttled, other, sample = error_causes(base, token, eval_id, run_id)
        if throttled and not other:
            return (ModelResult(deployment, FAIL,
                                "{}/{} items rate limited (HTTP 429) - the deployment needs more "
                                "TPM quota, this is not a model quality failure".format(errored, total),
                                counts, elapsed, run_url),
                    "{}/{} items rate limited".format(throttled, total))

        detail = "{}/{} items errored before grading".format(errored, total)
        run_error = run.get("error") or {}
        if sample:
            detail += " ({})".format(sample)
        elif isinstance(run_error, dict) and run_error.get("message"):
            detail += " ({})".format(run_error["message"])
        return ModelResult(deployment, FAIL, detail, counts, elapsed, run_url), ""

    rate = float(passed) / float(total)
    detail = "{}/{} passed ({:.0%})".format(passed, total, rate)

    # The API reports status "completed" even when every assertion failed, so
    # the gate reads result_counts rather than the run status.
    if rate + 1e-9 < plan["pass_threshold"]:
        return (ModelResult(deployment, FAIL,
                            "{}, below threshold {:.0%}".format(detail, plan["pass_threshold"]),
                            counts, elapsed, run_url), "")
    if failed:
        detail += ", {} failed".format(failed)
    return ModelResult(deployment, PASS, detail, counts, elapsed, run_url), ""


def resolve_endpoint(args):
    if args.endpoint:
        return args.endpoint.rstrip("/")
    endpoint = run_az([
        "cognitiveservices", "account", "show",
        "--name", args.foundry_name, "--resource-group", args.resource_group,
        "--query", "properties.endpoint", "-o", "tsv",
    ])
    if not endpoint:
        print("ERROR: could not resolve endpoint for {}".format(args.foundry_name), file=sys.stderr)
        sys.exit(2)
    return endpoint.rstrip("/")


def parse_args():
    p = argparse.ArgumentParser(description="Run Foundry model evaluations as a deployment gate.")
    p.add_argument("--foundry-name", required=True, help="Foundry (Cognitive Services) account name.")
    p.add_argument("--resource-group", required=True, help="Resource group containing the account.")
    p.add_argument("--endpoint", default="", help="Override the resolved account endpoint.")
    p.add_argument("--dataset", default="",
                   help="Force one JSONL dataset for every deployment, overriding per-model "
                        "resolution. Leave unset to use evaluations/<deployment>.jsonl when present.")
    p.add_argument("--default-dataset", default="evaluations/default.jsonl",
                   help="Fallback dataset for deployments with no per-model file or manifest entry.")
    p.add_argument("--manifest", default="evaluations/models.json",
                   help="Optional JSON manifest of per-model datasets and thresholds.")
    p.add_argument("--deployment", action="append", default=[],
                   help="Evaluate only this deployment (repeatable).")
    p.add_argument("--pass-threshold", type=float, default=None,
                   help="Override the minimum fraction of graded items that must pass "
                        "(otherwise use the manifest threshold, default 0.8).")
    p.add_argument("--similarity-threshold", type=float, default=0.6,
                   help="Threshold for the text_similarity grader (default 0.6).")
    p.add_argument("--similarity-metric", default="fuzzy_match",
                   choices=["fuzzy_match", "bleu", "rouge_l", "meteor"],
                   help="Metric for the text_similarity grader (default fuzzy_match).")
    p.add_argument("--system-prompt", default="Answer as concisely as possible.",
                   help="System prompt used for every evaluated model.")
    p.add_argument("--max-completions-tokens", type=int, default=2000,
                   help="Completion token budget per item (default 2000). Reasoning models "
                        "spend hidden tokens first, so a small budget yields empty answers. "
                        "Set to 0 to let the service choose.")
    p.add_argument("--max-run-retries", type=int, default=2,
                   help="Retries when a run is rate limited rather than genuinely wrong (default 2).")
    p.add_argument("--retry-delay", type=int, default=30,
                   help="Seconds to wait before retrying a rate-limited run (default 30).")
    p.add_argument("--run-timeout", type=int, default=900,
                   help="Seconds to wait for a single run to finish (default 900).")
    p.add_argument("--poll-interval", type=int, default=10,
                   help="Seconds between run status polls (default 10).")
    p.add_argument("--keep-eval", action="store_true",
                   help="Keep the created evaluation instead of deleting it afterwards.")
    return p.parse_args()


def main():
    args = parse_args()

    if args.pass_threshold is not None and not 0.0 <= args.pass_threshold <= 1.0:
        print("ERROR: --pass-threshold must be between 0 and 1.", file=sys.stderr)
        return 2

    manifest = load_manifest(args.manifest)
    endpoint = resolve_endpoint(args)
    base = endpoint + "/openai/v1"
    token = get_token()

    raw_deployments = json.loads(run_az([
        "cognitiveservices", "account", "deployment", "list",
        "--name", args.foundry_name, "--resource-group", args.resource_group, "-o", "json",
    ]) or "[]")

    by_name = {d.get("name"): d for d in raw_deployments}
    if args.deployment:
        unknown = [d for d in args.deployment if d not in by_name]
        if unknown:
            print("ERROR: deployment(s) not found on {}: {}".format(
                args.foundry_name, ", ".join(unknown)), file=sys.stderr)
            return 2
        selected = [by_name[d] for d in args.deployment]
    else:
        selected = sorted(raw_deployments, key=lambda d: d.get("name") or "")

    if not selected:
        print("ERROR: no model deployments found on {}.".format(args.foundry_name), file=sys.stderr)
        return 2

    print("Model evaluation for '{}'".format(args.foundry_name))
    print("  endpoint:       {}".format(endpoint))
    if args.dataset:
        print("  dataset:        {} (forced for every deployment)".format(args.dataset))
    else:
        print("  datasets:       per-model, falling back to {}".format(args.default_dataset))
        print("  manifest:       {}".format(
            args.manifest if manifest else "{} (not present)".format(args.manifest)))
    print("  pass threshold: {}".format(
        "{:.0%} of items (override)".format(args.pass_threshold)
        if args.pass_threshold is not None else "per-model, default 80%"))
    print("  deployments:    {}".format(len(selected)))
    print("")

    run_stamp = int(time.time())
    # The grading criteria live on the evaluation, not the run, so deployments
    # that share criteria share one evaluation. A model with its own similarity
    # settings gets its own evaluation rather than silently reusing another's.
    evals = {}
    datasets = {}

    def get_eval(plan):
        key = (plan["similarity_metric"], plan["similarity_threshold"])
        if key not in evals:
            eval_name = "ci-{}-{}-{}".format(args.foundry_name, run_stamp, len(evals) + 1)
            status, created, raw = api(
                base, "POST", "/evals", token,
                body=build_eval_body(eval_name, plan["similarity_metric"],
                                     plan["similarity_threshold"]))
            if status not in (200, 201) or not isinstance(created, dict):
                raise RuntimeError("could not create evaluation: {}".format(
                    redact(http_failure(status, created, raw), token)))
            evals[key] = created["id"]
            print("     created evaluation {} (text_similarity {} >= {})".format(
                created["id"], plan["similarity_metric"], plan["similarity_threshold"]))
        return evals[key]

    def get_dataset(path):
        if path not in datasets:
            datasets[path] = load_dataset(path)
        return datasets[path]

    results = []
    fatal = ""
    try:
        for dep in selected:
            name = dep.get("name") or "<unnamed>"
            model = (dep.get("properties", {}) or {}).get("model", {}) or {}
            sku = (dep.get("sku", {}) or {}).get("name", "") or "?"
            print("  -> {} ({} {}, {})".format(
                name, model.get("name", "?"), model.get("version", "?"), sku))

            provisioning = (dep.get("properties", {}) or {}).get("provisioningState", "")
            if provisioning and provisioning != "Succeeded":
                results.append(ModelResult(name, FAIL, "provisioningState is {}".format(provisioning)))
                print("     FAIL  provisioningState is {}".format(provisioning))
                continue

            kind, why = classify(dep)
            if kind is None:
                results.append(ModelResult(name, SKIP, why))
                print("     SKIP  {}".format(why))
                continue

            plan = resolve_plan(name, args, manifest)
            content = get_dataset(plan["dataset"])
            print("     dataset {} ({} items, {}), threshold {:.0%}".format(
                plan["dataset"], len(content), plan["dataset_source"], plan["pass_threshold"]))

            result = evaluate_deployment(base, token, get_eval(plan), name, content, plan, args)
            result.dataset = plan["dataset"]
            results.append(result)
            print("     {}  {}  ({:.0f}s)".format(result.status, result.detail, result.elapsed))
    except RuntimeError as exc:
        # Creating an evaluation is setup, not a model verdict. Record it and
        # fall through to the finally block so anything already created is
        # still cleaned up, then exit 2 rather than reporting a model failure.
        fatal = str(exc)
    finally:
        if args.keep_eval:
            print("\nKeeping evaluation(s) {} (--keep-eval).".format(", ".join(evals.values())))
        else:
            for eval_id in evals.values():
                del_status, _, _ = api(base, "DELETE", "/evals/{}".format(eval_id), token)
                if del_status not in (200, 204):
                    print("\n::warning::Could not delete evaluation {} (HTTP {}). "
                          "Delete it manually to avoid clutter.".format(eval_id, del_status))

    if fatal:
        print("ERROR: {}".format(fatal), file=sys.stderr)
        return 2

    passed = [r for r in results if r.status == PASS]
    failed = [r for r in results if r.status == FAIL]
    skipped = [r for r in results if r.status == SKIP]
    blocked = [r for r in results if r.status == BLOCKED]

    print("")
    print("{:<26} {:<7} {:<28} {}".format("DEPLOYMENT", "RESULT", "DATASET", "DETAIL"))
    print("-" * 110)
    for r in results:
        print("{:<26} {:<7} {:<28} {}".format(
            r.name, r.status, os.path.basename(r.dataset) if r.dataset else "-", r.detail))
    print("-" * 110)
    print("{} passed, {} failed, {} blocked, {} skipped".format(
        len(passed), len(failed), len(blocked), len(skipped)))

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        icon = {PASS: ":white_check_mark:", FAIL: ":x:", SKIP: ":fast_forward:",
                BLOCKED: ":warning:"}
        with open(summary_path, "a", encoding="utf-8") as fh:
            fh.write("### Model evaluation - `{}`\n\n".format(args.foundry_name))
            fh.write("Each deployment is graded against its own dataset, because models "
                     "phrase correct answers differently.\n\n")
            fh.write("| Deployment | Result | Dataset | Detail |\n|---|---|---|---|\n")
            for r in results:
                fh.write("| `{}` | {} | {} | {} |\n".format(
                    r.name, icon.get(r.status, r.status),
                    "`{}`".format(os.path.basename(r.dataset)) if r.dataset else "-",
                    r.detail))
            fh.write("\n**{} passed, {} failed, {} blocked, {} skipped**\n".format(
                len(passed), len(failed), len(blocked), len(skipped)))
            if blocked:
                fh.write("\n> Blocked deployments were rate limited (HTTP 429), not wrong. "
                         "That is a TPM quota shortfall on the deployment, so raise its "
                         "capacity in the `.bicepparam` rather than editing the dataset.\n")

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for r in failed:
            print("::error::Model evaluation failed for '{}': {}".format(r.name, r.detail))
        for r in blocked:
            print("::error::Model evaluation blocked for '{}': {} "
                  "(capacity problem, not a model quality failure)".format(r.name, r.detail))

    # Distinct exit codes: 1 means the models answered wrongly, 2 means the run
    # could not produce a verdict. Collapsing them would let a quota shortfall
    # masquerade as a quality regression.
    if blocked:
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
