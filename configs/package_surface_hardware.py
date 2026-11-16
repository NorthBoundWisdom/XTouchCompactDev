#!/usr/bin/env python3
"""Package a clean hardware root and distinct simulation artifact; preserve all old deliveries."""

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
    from .package_surface_simulator import (
        ROOT,
        SHARED,
        TEST_SUPPORT_ZIP,
        command,
        kernel_provenance,
        source_provenance,
        stage_shared_files,
        stage_test_support,
        test_support_sources,
    )
    from .package_surface_simulator import (
        write_manifest as write_simulator_manifest,
    )
except ImportError:
    from delivery_index import publish
    from package_surface_simulator import (
        ROOT,
        SHARED,
        TEST_SUPPORT_ZIP,
        command,
        kernel_provenance,
        source_provenance,
        stage_shared_files,
        stage_test_support,
        test_support_sources,
    )
    from package_surface_simulator import (
        write_manifest as write_simulator_manifest,
    )

SHARED_FILES = {
    "surface-control-diagnostic-capture.schema.json": "docs/surface-control-diagnostic-capture.schema.json",
    "surface-control-diagnostic-capture-v1.5.schema.json": "docs/surface-control-diagnostic-capture-v1.5.schema.json",
    **{
        name: "docs/" + name
        for name in (
            "surface-control-input-retention-tools.json",
            "surface-control-input-retention-examples.json",
            "surface-control-input-retention-hardware-tools.json",
            "surface-control-input-retention-hardware-examples.json",
        )
    },
    "surface-control-diagnostics.md": "docs/surface-control-diagnostics.md",
    "status-panel-demo.md": "docs/status-panel-demo.md",
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
SDK_ZIP = "surface-control-sdk-1.5.0.zip"


def sdk_sources():
    python = SHARED / "clients/python"
    return sorted(
        path
        for package in (
            "surface_control",
            "surface_conformance",
            "surface_control_diagnostics",
            "surface_panel_demo",
        )
        for path in (python / package).rglob("*")
        if path.is_file() and path.suffix in (".py", ".md", ".json")
    )


def stage_files(stage):
    shutil.copy2(ROOT / "configs/generate_owned_virtual_mapping.py", stage / "generate_owned_virtual_mapping.py")
    shutil.copy2(ROOT / "docs/OWNED_VIRTUAL_REHEARSAL.md", stage / "owned-virtual-rehearsal.md")
    for name, source in SHARED_FILES.items():
        shutil.copy2(SHARED / source, stage / name)
    for source, name in (
        ("LICENSE", "LICENSE"),
        ("docs/SURFACE_HARDWARE.md", "README.md"),
        ("docs/DISPLAY_TARGETS_HARDWARE.md", "display-targets.md"),
        ("docs/DISPLAY_BUDGET.md", "display-budget.md"),
        ("configs/check_display_targets.py", "check_display_targets.py"),
        ("configs/surface_plugins.lock.json", "surface_plugins.lock.json"),
        ("examples/surface_hardware/conformance-roles.json", "conformance-roles.json"),
        ("configs/verify_hardware_delivery.py", "verify_hardware_delivery.py"),
        ("configs/surface_sdk_metadata.py", "surface_sdk_metadata.py"),
        ("configs/verify_hardware_http.py", "verify_hardware_http.py"),
        ("configs/verify_simulation_delivery.py", "verify_simulation_delivery.py"),
    ):
        shutil.copy2(ROOT / source, stage / name)
    with zipfile.ZipFile(stage / SDK_ZIP, "w") as sdk:
        for source in sdk_sources():
            entry = zipfile.ZipInfo(str(source.relative_to(SHARED / "clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            sdk.writestr(entry, source.read_bytes())

    stage_test_support(stage)


def package(output_root, configuration="release"):
    if command("git", "status", "--porcelain"):
        raise RuntimeError("Hardware delivery requires clean committed HEAD")
    subprocess.run(["python3", "configs/surface_plugins_dependency.py", "verify"], cwd=ROOT, check=True)
    subprocess.run(["python3", "configs/control_surface_kit_dependency.py", "verify"], cwd=ROOT, check=True)
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
        simulation = stage / "simulation"
        simulation.mkdir()
        shutil.copy2(binaries / "XTouchSurfaceSimulator", simulation)
        stage_shared_files(simulation)
        (simulation / "control-contract.json").write_bytes(
            subprocess.check_output([str(simulation / "XTouchSurfaceSimulator"), "--describe"])
        )
        subprocess.run(
            [
                "python3",
                str(simulation / "check_display_targets.py"),
                "--contract",
                str(simulation / "control-contract.json"),
                "--table",
                str(simulation / "display-targets.md"),
            ],
            check=True,
        )
        write_simulator_manifest(simulation, command("git", "rev-parse", "HEAD"), configuration)
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
        subprocess.run(
            [
                "python3",
                str(stage / "check_display_targets.py"),
                "--contract",
                str(stage / "control-contract.json"),
                "--table",
                str(stage / "display-targets.md"),
            ],
            check=True,
        )
        discovery = json.loads(described)["discovery"]
        if discovery["source"] != "hardware" or discovery["contract_version"] != "1.4":
            raise RuntimeError("Hardware binary discovery mismatch")
        manifest = {
            "schema_version": 1,
            **source_provenance(),
            "artifact": "surface-control-hardware",
            "product": "XTouchSurfaceHardware",
            "source": "hardware",
            "source_commit": command("git", "rev-parse", "HEAD"),
            "source_dirty": False,
            "surface_control_contract": "1.4",
            "surface_control_sdk": "1.5.0",
            **kernel_provenance(ROOT),
            "profile_id": discovery["profile"]["id"],
            "profile_version": discovery["profile"]["version"],
            "mapping_revision": discovery["expected"]["mapping_revision"],
            "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())[
                "revision"
            ],
            "surface_plugins_files_sha256": {
                str(path.relative_to(SHARED)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in [
                    *(SHARED / source for source in SHARED_FILES.values()),
                    *sdk_sources(),
                    *(SHARED / source for source in test_support_sources()),
                ]
            },
            "files_sha256": {
                str(path.relative_to(stage)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(stage.rglob("*"))
                if path.is_file()
            },
            "test_artifacts": [
                {
                    "artifact": "surface-control-test-only-hardware-double",
                    "qualification": "test-only",
                    "path": TEST_SUPPORT_ZIP,
                }
            ],
            "simulation_artifact": {
                "directory": "simulation",
                "manifest": "simulation/manifest.json",
                "source": "simulation",
                "contract": "1.3",
                "qualification": "software-only",
            },
            "offline_diagnostic_mode": {
                "argument": "--device-access disabled",
                "device_access": "disabled",
                "link": "disconnected",
                "qualification": "diagnostic HTTP only; no connected hardware",
            },
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
