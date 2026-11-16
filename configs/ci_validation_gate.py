#!/usr/bin/env python3
"""Permit native execution only after this exact run/attempt/SHA's validation job succeeds."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
import urllib.request
from datetime import datetime, timezone


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def wait_for_validation(fetch, *, repository, run_id, attempt, consumer, producer, now=lambda: datetime.now(timezone.utc), pause=time.sleep):
    started = now()
    run = fetch("", 15)
    if str(run["id"]) != str(run_id) or int(run["run_attempt"]) != int(attempt) or run["repository"]["full_name"] != repository:
        raise RuntimeError("Validation gate run/repository/attempt identity mismatch")
    created = instant(run["created_at"])
    first_poll = True
    while True:
        remaining = 300 - (now() - created).total_seconds()
        if remaining <= 0:
            raise RuntimeError("Whole-run 300s budget expired waiting for validation")
        if not first_poll:
            current_run = fetch("", min(15, remaining))
            if (str(current_run["id"]) != str(run_id) or int(current_run["run_attempt"]) != int(attempt)
                    or current_run["repository"]["full_name"] != repository or current_run["head_sha"] != run["head_sha"]
                    or current_run["created_at"] != run["created_at"]):
                raise RuntimeError("Validation gate run/attempt/SHA changed while waiting")
        first_poll = False
        reply = fetch(f"/attempts/{attempt}/jobs?per_page=100", min(15, remaining))
        jobs = reply["jobs"]
        if reply.get("total_count", len(jobs)) > len(jobs):
            raise RuntimeError("Validation job identity is incomplete; refusing a partial job page")
        selected = {}
        for name in (consumer, producer):
            matches = [job for job in jobs if job["name"] == name]
            if len(matches) != 1:
                raise RuntimeError("Cannot identify exactly one current validation/consumer job")
            job = matches[0]
            if str(job["run_id"]) != str(run_id) or int(job["run_attempt"]) != int(attempt) or job["head_sha"] != run["head_sha"]:
                raise RuntimeError("Validation gate job run/attempt/SHA mismatch")
            selected[name] = job
        validation = selected[producer]
        if validation["status"] == "completed":
            if validation["conclusion"] != "success":
                raise RuntimeError("Validation producer failed; native execution remains closed")
            if (now() - created).total_seconds() >= 300:
                raise RuntimeError("Whole-run 300s budget expired at validation completion")
            return {"repository": repository, "run_id": run_id, "attempt": attempt, "head_sha": run["head_sha"],
                    "validation_job_id": validation["id"], "consumer_job_id": selected[consumer]["id"],
                    "validation_conclusion": "success", "wait_seconds": (now() - started).total_seconds()}
        if validation.get("conclusion") is not None:
            raise RuntimeError("Validation producer has an inconsistent nonterminal conclusion")
        remaining = 300 - (now() - created).total_seconds()
        if remaining <= 0:
            raise RuntimeError("Whole-run 300s budget expired waiting for validation")
        pause(min(2, remaining))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--producer", default="validation-macos")
    args = parser.parse_args(argv)
    env = os.environ
    checkout = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if checkout != env["GITHUB_SHA"]:
        raise RuntimeError("Native checkout SHA does not match the explicit workflow ref")
    # Both jobs explicitly checkout github.sha. API head_sha is also compared between
    # run and both jobs: PR merge refs are not incorrectly confused with API head SHA.
    base = f"{env.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
    headers = {"Authorization": "Bearer " + env["GH_TOKEN"], "Accept": "application/vnd.github+json"}

    def fetch(suffix, timeout):
        request = urllib.request.Request(base + suffix, headers=headers)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)

    result = wait_for_validation(fetch, repository=env["GITHUB_REPOSITORY"], run_id=env["GITHUB_RUN_ID"],
                                 attempt=env["GITHUB_RUN_ATTEMPT"], consumer=env.get("CI_JOB_NAME", env["GITHUB_JOB"]), producer=args.producer)
    result["checkout_sha"] = checkout
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
