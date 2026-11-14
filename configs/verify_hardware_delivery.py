#!/usr/bin/env python3
"""Source-independent describe-only hardware delivery verification; never opens MIDI."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def verify(directory):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / "manifest.json").read_text())
    for name, digest in manifest["files_sha256"].items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("Invalid delivery path")
        if hashlib.sha256((directory / relative).read_bytes()).hexdigest() != digest:
            raise RuntimeError("Delivery hash mismatch: " + name)
    with tempfile.TemporaryDirectory() as scratch:
        with zipfile.ZipFile(directory / "surface-control-sdk-1.4.0.zip") as sdk:
            sdk.extractall(scratch)
        sys.dont_write_bytecode = True
        sys.path.insert(0, scratch)
        from surface_conformance import select_roles, validate_roles
        from surface_control import mapping_revision, validate_hardware_profile

        environment = dict(os.environ)
        environment.pop("XTOUCH_HARDWARE_TEST_SCRIPT", None)
        environment.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
        output = subprocess.check_output(
            [
                str(directory / "XTouchSurfaceHardware"),
                "--describe",
                "--receive-channel",
                "2",
                "--light-protocol",
                "observed114",
            ],
            cwd=scratch,
            env=environment,
            text=True,
        )
        discovery = json.loads(output)["discovery"]
        validate_hardware_profile(discovery["profile"])
        assert discovery["source"] == "hardware" and discovery["contract_version"] == "1.4"
        assert (
            mapping_revision(discovery["profile"])
            == manifest["mapping_revision"]
            == discovery["expected"]["mapping_revision"]
        )
        assert discovery["profile"]["id"] == manifest["profile_id"]
        assert len(discovery["profile"]["controls"]) == 182
        roles = json.loads((directory / "conformance-roles.json").read_text())
        for fixture_name in ("surface-control-hardware-v1.4.json", "surface-control-hardware-independent-v1.4.json"):
            fixture = json.loads((directory / fixture_name).read_text())
            validate_roles(select_roles(roles, fixture), fixture, discovery["profile"])
    return {
        "scope": "outside-source-describe-only",
        "source": "hardware",
        "checks": [
            "all-delivery-file-hashes",
            "delivered-binary-describe",
            "delivered-sdk-profile-validation",
            "mapping-revision",
            "delivered-checker-role-validation",
        ],
        "pass": 5,
        "fail": 0,
        "hardware_connected": False,
        "http_exercised": False,
        "feedback_sent": 0,
    }


if __name__ == "__main__":
    print(json.dumps(verify(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent), sort_keys=True))
