#!/usr/bin/env python3
"""Package a clean macOS display-only hardware service; never rebuild simulator deliveries."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

try:
    from .delivery_index import publish
    from .package_surface_simulator import ROOT, SHARED, command
except ImportError:
    from delivery_index import publish
    from package_surface_simulator import ROOT, SHARED, command

SHARED_FILES = {
    "control-tools.json": "docs/surface-control-hardware-tools.json",
    "control-examples.json": "docs/surface-control-hardware-examples.json",
    "surface-control-hardware-v1.4.json": "fixtures/surface-control-hardware-v1.4.json",
    "surface-control-hardware-independent-v1.4.json": "fixtures/surface-control-hardware-independent-v1.4.json",
    **{
        name: "docs/" + name
        for name in (
            "surface-control-scenario.schema.json",
            "surface-control.md",
            "surface-control-scenarios.md",
            "surface-control-delivery.md",
            "surface-control-conformance.md",
            "surface-control-conformance-report.schema.json",
            "versioning.md",
        )
    },
}
SDK_ZIP = "surface-control-sdk-1.4.0.zip"


def sdk_sources():
    python = SHARED / "clients/python"
    return sorted(
        path
        for package in ("surface_control", "surface_conformance", "surface_control_testing")
        for path in (python / package).rglob("*")
        if path.is_file() and path.suffix in (".py", ".md")
    )


def stage_files(stage):
    for name, source in SHARED_FILES.items():
        shutil.copy2(SHARED / source, stage / name)
    for source, name in (
        ("LICENSE", "LICENSE"),
        ("docs/SURFACE_HARDWARE.md", "README.md"),
        ("configs/surface_plugins.lock.json", "surface_plugins.lock.json"),
        ("examples/surface_hardware/conformance-roles.json", "conformance-roles.json"),
        ("configs/verify_hardware_delivery.py", "verify_hardware_delivery.py"),
    ):
        shutil.copy2(ROOT / source, stage / name)
    with zipfile.ZipFile(stage / SDK_ZIP, "w") as sdk:
        for source in sdk_sources():
            entry = zipfile.ZipInfo(str(source.relative_to(SHARED / "clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            sdk.writestr(entry, source.read_bytes())


def package(output_root, configuration="release"):
    if command("git", "status", "--porcelain"):
        raise RuntimeError("Hardware delivery requires clean committed HEAD")
    subprocess.run(["python3", "configs/surface_plugins_dependency.py", "verify"], cwd=ROOT, check=True)
    scratch = ROOT / "build/surface-hardware" / configuration
    subprocess.run(
        [
            "swift",
            "build",
            "--jobs",
            "2",
            "--configuration",
            configuration,
            "--scratch-path",
            str(scratch),
            "--product",
            "XTouchSurfaceHardware",
        ],
        cwd=ROOT,
        check=True,
    )
    binaries = Path(
        command("swift", "build", "--configuration", configuration, "--scratch-path", str(scratch), "--show-bin-path")
    )
    output_root = Path(output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".surface-hardware-", dir=output_root))
    try:
        shutil.copy2(binaries / "XTouchSurfaceHardware", stage)
        stage_files(stage)
        described = subprocess.check_output(
            [
                str(stage / "XTouchSurfaceHardware"),
                "--describe",
                "--receive-channel",
                "2",
                "--light-protocol",
                "observed114",
            ],
            text=True,
        )
        (stage / "control-contract.json").write_text(described)
        discovery = json.loads(described)["discovery"]
        if discovery["source"] != "hardware" or discovery["contract_version"] != "1.4":
            raise RuntimeError("Hardware binary discovery mismatch")
        manifest = {
            "schema_version": 1,
            "artifact": "surface-control-hardware",
            "product": "XTouchSurfaceHardware",
            "source": "hardware",
            "source_commit": command("git", "rev-parse", "HEAD"),
            "source_dirty": False,
            "surface_control_contract": "1.4",
            "surface_control_sdk": "1.4.0",
            "profile_id": discovery["profile"]["id"],
            "profile_version": discovery["profile"]["version"],
            "mapping_revision": discovery["expected"]["mapping_revision"],
            "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())[
                "revision"
            ],
            "surface_plugins_files_sha256": {
                str(path.relative_to(SHARED)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in [*(SHARED / source for source in SHARED_FILES.values()), *sdk_sources()]
            },
            "files_sha256": {
                str(path.relative_to(stage)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(stage.rglob("*"))
                if path.is_file()
            },
            "test_artifacts": [{"artifact": "surface-control-test-only-hardware-double", "qualification": "test-only"}],
            "device_configuration": {
                "transmit_channel": 1,
                "receive_channel": 2,
                "light_protocol": "observed114",
                "qualification": "requires attended per-unit acceptance",
            },
            "platform": os.uname().sysname,
            "architecture": os.uname().machine,
            "configuration": configuration,
            "start_protocol": "private token; loopback /mcp; required receive channel and light protocol; feedback defaults off",
            "stop_protocol": "terminate isolated process; zero exit device output",
        }
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        return publish(stage, output_root, "xtouch")
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=ROOT.parent / "deliveries")
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    print(package(args.output_root, args.configuration))
