#!/usr/bin/env python3
"""Post-deployment inference validation for a Microsoft Foundry resource.

Sends a small live request to every model deployment on the account and reports
whether each one actually serves traffic. This catches problems that a
successful ARM deployment does not: a deployment can reach provisioningState
'Succeeded' while still failing at inference time (quota exhausted at first
call, content filter misconfiguration, a model retired behind the deployment
name, or a capability the endpoint does not actually expose).

Authentication is Microsoft Entra ID only -- the Foundry resource is deployed
with disableLocalAuth: true, so a bearer token is acquired from the Azure CLI
login rather than an API key.

Uses only the Python standard library so it runs on a stock GitHub-hosted
runner with no pip install step.

Examples:
    python3 scripts/validate-inference.py \
        --foundry-name devmfdfoundry001 --resource-group dev-mfd-foundry-rg

    # Check a single deployment
    python3 scripts/validate-inference.py \
        --foundry-name devmfdfoundry001 --resource-group dev-mfd-foundry-rg \
        --deployment gpt-4o

Exit codes:
    0  every applicable deployment answered correctly
    1  at least one deployment failed
    2  the script could not run (login, endpoint lookup, no deployments)
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

# Batch deployments accept work only through the asynchronous /batches API, which
# uploads a JSONL file and returns results over minutes-to-hours. That is not
# viable as a deployment gate, so they are reported as skipped rather than run.
BATCH_SKU_MARKER = "batch"

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"

# HTTP statuses worth retrying: throttling and transient server-side faults.
# A 400/404 is deterministic -- retrying only slows the run down.
RETRYABLE_STATUS = {429, 500, 502, 503, 504}

# 401/403 is normally deterministic, but immediately after a deployment that just created the
# caller's "Cognitive Services OpenAI User" assignment it is usually only RBAC propagation, which
# resolves within a minute. Azure evaluates data-plane RBAC per request rather than baking it into
# the token, so simply re-sending the same token succeeds once replication catches up. Retried on a
# separate, smaller budget so a genuinely missing role still fails reasonably fast.
AUTH_STATUS = {401, 403}
AUTH_MAX_ATTEMPTS = 4


class Result:
    def __init__(self, name, status, kind, detail, elapsed=0.0):
        self.name = name
        self.status = status
        self.kind = kind
        self.detail = detail
        self.elapsed = elapsed


def run_az(args):
    """Invoke the Azure CLI and return stdout, or exit with a clear message.

    Exits 2 ("could not run"), not 1 ("a model failed") -- a missing CLI or an
    unresolvable account means the check never got as far as testing a model,
    and callers distinguish the two.
    """
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


def post_json(url, payload, token, timeout, max_attempts):
    """POST with retries on throttling/transient errors.

    Returns (status_code, parsed_body_or_none, raw_text).
    """
    body = json.dumps(payload).encode("utf-8")
    attempt = 1
    while True:
        req = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        )
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
            raw = "connection error: {}".format(exc.reason)
        except TimeoutError:
            raw = "request timed out after {}s".format(timeout)

        if status == 200:
            try:
                return status, json.loads(raw), raw
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

        # Honour Retry-After when the service supplies it; otherwise back off.
        delay = 2 ** attempt
        if status in AUTH_STATUS:
            # Exponential backoff tops out around 14s total, which is too short for RBAC
            # replication. Use a flat, longer wait so the budget spans ~45s instead.
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
    """Pull the human-readable message out of an Azure OpenAI error envelope."""
    if isinstance(parsed, dict):
        err = parsed.get("error")
        if isinstance(err, dict) and err.get("message"):
            return str(err["message"])
        if isinstance(err, str):
            return err
    return " ".join(raw.split())[:300]


def http_failure(status, parsed, raw, args):
    """Format an HTTP failure, adding remediation for the ones with a known cause.

    401/403 is the failure most likely to hit a pipeline rather than a developer:
    inference is a *data-plane* action, and the control-plane roles a deployment
    identity normally holds (Contributor, Owner, User Access Administrator) carry
    no dataActions at all. The identity needs an explicit data-plane role.
    """
    detail = "HTTP {}: {}".format(status or "network error", error_message(parsed, raw))
    if status in (401, 403):
        detail += (
            " | Inference is a data-plane action; control-plane roles do not grant it."
            " Assign 'Cognitive Services OpenAI User' to the calling identity:"
            " az role assignment create --assignee <objectId>"
            " --role 'Cognitive Services OpenAI User' --scope <foundry-account-resource-id>"
        )
    return detail


def test_chat(base, name, api_version, token, args):
    """Chat-completion probe.

    Reasoning models (gpt-5.x) spend the completion budget on hidden reasoning
    tokens, so a small cap returns empty content with finish_reason='length' --
    which looks like a failure but is not. The default budget is deliberately
    generous enough to leave room for a visible answer.
    """
    url = "{}/openai/deployments/{}/chat/completions?api-version={}".format(base, name, api_version)
    payload = {
        "messages": [{"role": "user", "content": args.prompt}],
        "max_completion_tokens": args.max_completion_tokens,
    }
    started = time.time()
    status, parsed, raw = post_json(url, payload, token, args.timeout, args.max_attempts)

    # Older models predate max_completion_tokens and reject it; fall back once.
    if status == 400 and "max_completion_tokens" in error_message(parsed, raw):
        payload.pop("max_completion_tokens")
        payload["max_tokens"] = args.max_completion_tokens
        status, parsed, raw = post_json(url, payload, token, args.timeout, args.max_attempts)

    elapsed = time.time() - started
    if status != 200:
        return Result(name, FAIL, "chat",
                      http_failure(status, parsed, raw, args), elapsed)

    try:
        choice = parsed["choices"][0]
        content = (choice["message"].get("content") or "").strip()
        finish = choice.get("finish_reason")
    except (KeyError, IndexError, TypeError):
        return Result(name, FAIL, "chat",
                      "unexpected response shape: {}".format(" ".join(raw.split())[:200]), elapsed)

    if not content:
        return Result(
            name, FAIL, "chat",
            "empty content (finish_reason={}); raise --max-completion-tokens "
            "if this is a reasoning model".format(finish),
            elapsed,
        )

    served = parsed.get("model", "")
    detail = 'replied "{}"'.format(content[:40])
    # model-router picks an underlying model per request; surface which one answered.
    if served and served != name:
        detail += " (served by {})".format(served)
    return Result(name, PASS, "chat", detail, elapsed)


def test_embeddings(base, name, api_version, token, args):
    url = "{}/openai/deployments/{}/embeddings?api-version={}".format(base, name, api_version)
    started = time.time()
    status, parsed, raw = post_json(url, {"input": args.prompt}, token, args.timeout, args.max_attempts)
    elapsed = time.time() - started

    if status != 200:
        return Result(name, FAIL, "embeddings",
                      http_failure(status, parsed, raw, args), elapsed)
    try:
        vector = parsed["data"][0]["embedding"]
    except (KeyError, IndexError, TypeError):
        return Result(name, FAIL, "embeddings",
                      "unexpected response shape: {}".format(" ".join(raw.split())[:200]), elapsed)
    if not vector:
        return Result(name, FAIL, "embeddings", "returned an empty embedding vector", elapsed)
    return Result(name, PASS, "embeddings", "returned {}-dimension vector".format(len(vector)), elapsed)


def classify(deployment):
    """Decide how to probe a deployment. Returns (kind, reason).

    Order matters: a Batch deployment still advertises chatCompletion in its
    capabilities, so the SKU has to be checked before the capability flags.
    """
    props = deployment.get("properties", {})
    sku = (deployment.get("sku") or {}).get("name", "") or ""
    caps = props.get("capabilities") or {}

    def enabled(flag):
        return str(caps.get(flag, "")).lower() == "true"

    if BATCH_SKU_MARKER in sku.lower():
        return "skip", "{} serves the asynchronous Batch API only".format(sku)
    if enabled("chatCompletion"):
        return "chat", ""
    if enabled("embeddings"):
        return "embeddings", ""
    return "skip", "no chatCompletion or embeddings capability (sku {})".format(sku)


def main():
    parser = argparse.ArgumentParser(description="Validate live inference for Foundry model deployments.")
    parser.add_argument("--foundry-name", required=True, help="Foundry (Cognitive Services account) name")
    parser.add_argument("--resource-group", required=True, help="Resource group containing the account")
    parser.add_argument("--endpoint", help="Override the endpoint instead of looking it up via az")
    parser.add_argument("--api-version", default="2024-10-21", help="Azure OpenAI data-plane API version")
    parser.add_argument("--deployment", action="append", default=[],
                        help="Only test this deployment (repeatable). Default: all.")
    parser.add_argument("--prompt", default="Reply with the single word: OK", help="Probe prompt")
    parser.add_argument("--max-completion-tokens", type=int, default=256,
                        help="Completion budget. Must leave room for reasoning models' hidden tokens.")
    parser.add_argument("--timeout", type=int, default=120, help="Per-request timeout in seconds")
    parser.add_argument("--max-attempts", type=int, default=4, help="Attempts per request on 429/5xx")
    parser.add_argument("--fail-on-skip", action="store_true",
                        help="Treat skipped deployments as failures (default: skips are informational)")
    args = parser.parse_args()

    endpoint = (args.endpoint or run_az([
        "cognitiveservices", "account", "show",
        "--name", args.foundry_name, "--resource-group", args.resource_group,
        "--query", "properties.endpoint", "-o", "tsv",
    ])).rstrip("/")
    if not endpoint:
        print("ERROR: could not resolve the Foundry endpoint.")
        return 2

    raw_list = run_az([
        "cognitiveservices", "account", "deployment", "list",
        "--name", args.foundry_name, "--resource-group", args.resource_group, "-o", "json",
    ])
    deployments = json.loads(raw_list or "[]")
    if args.deployment:
        wanted = set(args.deployment)
        deployments = [d for d in deployments if d.get("name") in wanted]
        missing = wanted - set(d.get("name") for d in deployments)
        if missing:
            print("ERROR: deployment(s) not found on {}: {}".format(
                args.foundry_name, ", ".join(sorted(missing))))
            return 2
    if not deployments:
        print("ERROR: no model deployments found on {}.".format(args.foundry_name))
        return 2

    token = get_token()
    deployments.sort(key=lambda d: d.get("name", ""))

    print("Inference validation for '{}'".format(args.foundry_name))
    print("  endpoint:    {}".format(endpoint))
    print("  api-version: {}".format(args.api_version))
    print("  deployments: {}".format(len(deployments)))
    print("")

    results = []
    for dep in deployments:
        name = dep.get("name", "<unnamed>")
        props = dep.get("properties", {})
        state = props.get("provisioningState", "Unknown")
        model = (props.get("model") or {}).get("name", "?")
        version = (props.get("model") or {}).get("version", "?")
        sku = (dep.get("sku") or {}).get("name", "?")
        print("  -> {} ({} {}, {})".format(name, model, version, sku))

        # A deployment that never finished provisioning cannot serve traffic.
        if state != "Succeeded":
            results.append(Result(name, FAIL, "state",
                                  "provisioningState is '{}', expected 'Succeeded'".format(state)))
            print("     FAIL  provisioningState={}".format(state))
            continue

        kind, reason = classify(dep)
        if kind == "skip":
            results.append(Result(name, SKIP, "n/a", reason))
            print("     SKIP  {}".format(reason))
            continue

        if kind == "chat":
            result = test_chat(endpoint, name, args.api_version, token, args)
        else:
            result = test_embeddings(endpoint, name, args.api_version, token, args)
        result.detail = redact(result.detail, token)
        results.append(result)
        print("     {}  {}  ({:.1f}s)".format(result.status, result.detail, result.elapsed))

    passed = [r for r in results if r.status == PASS]
    failed = [r for r in results if r.status == FAIL]
    skipped = [r for r in results if r.status == SKIP]

    print("")
    print("{:<26} {:<7} {:<11} DETAIL".format("DEPLOYMENT", "RESULT", "TEST"))
    print("-" * 100)
    for r in results:
        print("{:<26} {:<7} {:<11} {}".format(r.name, r.status, r.kind, r.detail))
    print("-" * 100)
    print("{} passed, {} failed, {} skipped".format(len(passed), len(failed), len(skipped)))

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        icon = {PASS: "OK", FAIL: "FAILED", SKIP: "SKIPPED"}
        with open(summary_path, "a", encoding="utf-8") as fh:
            fh.write("### Inference validation - `{}`\n\n".format(args.foundry_name))
            fh.write("**{} passed, {} failed, {} skipped**\n\n".format(
                len(passed), len(failed), len(skipped)))
            fh.write("| Deployment | Result | Test | Detail |\n|---|---|---|---|\n")
            for r in results:
                detail = r.detail.replace("|", "\\|")
                fh.write("| `{}` | {} | {} | {} |\n".format(r.name, icon.get(r.status, r.status), r.kind, detail))

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for r in failed:
            print("::error title=Inference failed: {}::{}".format(r.name, r.detail))
        for r in skipped:
            print("::notice title=Inference skipped: {}::{}".format(r.name, r.detail))

    if failed:
        return 1
    if skipped and args.fail_on_skip:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
