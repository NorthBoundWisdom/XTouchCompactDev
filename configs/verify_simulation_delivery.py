#!/usr/bin/env python3
"""Source-independent full simulation checker plus bounded read-only diagnostics.

Only package files are imported. Tokens use anonymous stdin pipes and memory, never files.
The hardware root is never launched by this verifier.
"""

import argparse
import hashlib
import importlib
import json
import os
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path

if not __debug__:
    raise SystemExit("Run without -O: these checks rely on assert")


def verify(directory, evidence):
    directory = Path(directory).resolve()
    evidence = Path(evidence).resolve()
    assert not evidence.is_relative_to(directory), "Evidence must be outside the delivery"
    evidence.mkdir(parents=True, exist_ok=True)
    simulation = directory / "simulation"
    for root in (directory, simulation):
        manifest = json.loads((root / "manifest.json").read_text())
        for name, digest in manifest["files_sha256"].items():
            relative = Path(name)
            assert not relative.is_absolute() and ".." not in relative.parts
            assert hashlib.sha256((root / relative).read_bytes()).hexdigest() == digest
    assert "surface_control" not in sys.modules
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(simulation / "surface-control-sdk-1.4.0.zip"))
    sdk = importlib.import_module("surface_control")
    checker = importlib.import_module("surface_conformance")
    diagnostics = importlib.import_module("surface_control_diagnostics")
    assert str(sdk.__file__).startswith(str(simulation)) and sdk.__version__ == "1.4.0"
    results = []
    environment = dict(os.environ)
    environment.pop("XTOUCH_HARDWARE_TEST_SCRIPT", None)
    environment.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
    with tempfile.TemporaryDirectory(prefix="xtouch-simulation-outside-") as scratch:
        token = secrets.token_hex(32)
        process = subprocess.Popen(
            [
                str(simulation / "XTouchSurfaceSimulator"),
                "--token-stdin",
                "--surface-instance-id",
                "outside.simulation",
                "--write-limit",
                "10000",
                "--allow-surface-input",
                "--allow-surface-feedback",
                "--allow-surface-reset",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=scratch,
            env=environment,
        )
        try:
            process.stdin.write(token + "\n")
            process.stdin.close()
            ready = json.loads(process.stdout.readline())
            assert ready["source"] == "simulation"
            client = sdk.Client(ready["url"], token, "outside.simulation")
            roles = json.loads((simulation / "conformance-roles.json").read_text())
            fixtures = sorted(simulation.glob("surface-control-software-v*.json"))
            assert len(fixtures) == 4
            for fixture in fixtures:
                report = checker.run_fixture(client, fixture.read_bytes(), roles)
                serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
                assert token not in serialized
                (evidence / fixture.name).write_text(serialized)
                assert report["counts"]["fail"] == 0
                results.append({"fixture": fixture.name, "counts": report["counts"]})
            manifest = json.loads((simulation / "manifest.json").read_text())
            reader = diagnostics.ReadOnlyClient(ready["url"], token, "outside.simulation")
            capture = diagnostics.capture(
                reader, manifest["profile_id"], manifest["profile_version"], limits={"max_polls": 1}
            )
            checked = diagnostics.verify(capture)
            serialized = json.dumps({"capture": capture, "verification": checked}, indent=2, sort_keys=True) + "\n"
            assert token not in serialized
            (evidence / "simulation-diagnostics.json").write_text(serialized)
            # The factory optional expression pedals have no observations in the default
            # simulator. A full-profile diagnostic must preserve those unknowns and report
            # incomplete, rather than fabricate values or silently narrow its scope.
            assert capture["end"]["exit_code"] == 1
            assert capture["end"]["reason"] == "unknown_inputs"
            assert capture["end"]["unknown_controls"] == ["a.expression.1", "b.expression.1"]
            assert checked["capture_integrity"] == "verified_recorded_invariants"
            assert checked["diagnostic_status"] == "incomplete_or_failed"
            assert checked["physical_qualification"] is False
            observed = diagnostics.capture(
                reader,
                manifest["profile_id"],
                manifest["profile_version"],
                required_controls=["a.fader.1", "a.touch.1", "a.encoder.1", "a.button.1"],
                limits={"max_polls": 1},
            )
            observed_checked = diagnostics.verify(observed)
            serialized = (
                json.dumps({"capture": observed, "verification": observed_checked}, indent=2, sort_keys=True) + "\n"
            )
            assert token not in serialized
            (evidence / "simulation-observed-controls-diagnostics.json").write_text(serialized)
            assert observed["end"]["exit_code"] == observed_checked["exit_code"] == 0
            assert observed_checked["diagnostic_status"] == "bounded_complete"
            assert observed_checked["physical_qualification"] is False
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
    result = {
        "scope": "outside-source-packaged-simulation-full",
        "fixtures": results,
        "all_profile_diagnostics": checked,
        "observed_control_diagnostics": observed_checked,
        "hardware_connected": False,
        "physical_qualification": False,
    }
    (evidence / "simulation-summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("delivery", type=Path)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.delivery, args.evidence), sort_keys=True))
