#!/usr/bin/env python3
"""Overlap runner setup with producers; consume only this run/attempt's exact named artifacts."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.request
from datetime import datetime, timezone


def wait_for_artifacts(fetch, names, producers, *, now=lambda: datetime.now(timezone.utc), pause=time.sleep):
    run = fetch("")
    created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    while (now() - created).total_seconds() < 300:
        artifacts = fetch("/artifacts?per_page=100")["artifacts"]
        found = [item["name"] for item in artifacts if item["name"] in names and not item["expired"]]
        if len(found) == len(names) and set(found) == set(names):
            return
        jobs = fetch(f"/attempts/{run['run_attempt']}/jobs?per_page=100")["jobs"]
        if any(
            job["name"].split(" (")[0] in producers
            and job.get("conclusion") in {"failure", "cancelled", "skipped", "timed_out"}
            for job in jobs
        ):
            raise RuntimeError("Artifact producer failed; no other run or attempt will be substituted")
        pause(2)
    raise RuntimeError("Whole-run 300s budget expired waiting for producer artifacts")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", action="append", required=True, help="Exact artifact name ending in this run attempt")
    parser.add_argument("--producer", action="append", required=True)
    args = parser.parse_args(argv)
    env = os.environ
    attempt = env["GITHUB_RUN_ATTEMPT"]
    if len(set(args.name)) != len(args.name) or any(not name.endswith("-attempt-" + attempt) for name in args.name):
        parser.error("Artifact names must be unique and scoped to this attempt")
    base = f"{env.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
    headers = {"Authorization": "Bearer " + env["GH_TOKEN"], "Accept": "application/vnd.github+json"}

    def fetch(suffix):
        with urllib.request.urlopen(urllib.request.Request(base + suffix, headers=headers), timeout=15) as response:
            value = json.load(response)
        if not suffix and (str(value["id"]) != env["GITHUB_RUN_ID"] or str(value["run_attempt"]) != attempt):
            raise RuntimeError("Workflow run/attempt changed during artifact wait")
        return value

    wait_for_artifacts(fetch, args.name, args.producer)
    print("This run/attempt's producer artifacts are ready")


if __name__ == "__main__":
    main()
