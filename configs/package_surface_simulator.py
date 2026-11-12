#!/usr/bin/env python3
"""Build an independent software-only delivery with hashes and exact source pins."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def default_output(root=ROOT):
    """Delivery directory named only after this repository's HEAD, never another host's commit."""
    short = subprocess.check_output(["git", "rev-parse", "--short=7", "HEAD"], cwd=root, text=True).strip()
    return root / "build" / "deliveries" / ("xtouch-surface-simulator-" + short)


SHARED = ROOT / "build/dependencies/SurfacePlugins"
SDK_VERSION = "1.1.0"
CONTRACT_VERSION = "1.1"
SDK_ZIP = "surface-control-sdk-" + SDK_VERSION + ".zip"
# Published shared files, copied byte for byte from the managed dependency (single source, D19-6).
# integrations/ and clients/python/tests are deliberately not part of a generic delivery.
SHARED_FILES = {
    "control-tools.json": "docs/surface-control-tools.json",
    "surface-control-scenario.schema.json": "docs/surface-control-scenario.schema.json",
    "surface-control-software-v1.json": "fixtures/surface-control-software-v1.json",
    "surface-control-software-v1.1.json": "fixtures/surface-control-software-v1.1.json",
    "surface-control.md": "docs/surface-control.md",
    "surface-control-scenarios.md": "docs/surface-control-scenarios.md",
}
SDK_SOURCE = "clients/python/surface_control/__init__.py"


def stage_shared_files(stage, root=ROOT, shared=SHARED):
    """Copy host files and shared published files into a delivery stage (no binary)."""
    shutil.copy2(root / "LICENSE", stage)
    shutil.copy2(root / "examples/surface_simulator/minimal_consumer.py", stage)
    shutil.copy2(root / "docs/SURFACE_SIMULATOR.md", stage / "README.md")
    shutil.copy2(root / "configs/surface_plugins.lock.json", stage)
    for name, source in SHARED_FILES.items():
        shutil.copy2(shared / source, stage / name)
    # Fixed timestamp and mode keep the zip reproducible for one shared revision.
    entry = zipfile.ZipInfo("surface_control/__init__.py", date_time=(1980, 1, 1, 0, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    entry.external_attr = 0o644 << 16
    with zipfile.ZipFile(stage / SDK_ZIP, "w") as sdk:
        sdk.writestr(entry, (shared / SDK_SOURCE).read_bytes())
    (stage / "examples").mkdir()
    shutil.copy2(root / "Clients/Python/examples/surface_roundtrip.py", stage / "examples" / "surface_roundtrip.py")


def write_manifest(stage, source_commit, configuration, root=ROOT, shared=SHARED):
    """Hash every staged file and record exact host/shared revisions and shared source hashes."""
    files = {
        str(path.relative_to(stage)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(stage.rglob("*"))
        if path.is_file()
    }
    revision = json.loads((root / "configs/surface_plugins.lock.json").read_text())["revision"]
    shared_sources = {
        source: hashlib.sha256((shared / source).read_bytes()).hexdigest()
        for source in [*SHARED_FILES.values(), SDK_SOURCE]
    }
    manifest = {
        "schema_version": 1,
        "product": "XTouchSurfaceSimulator",
        "source": "simulation",
        "source_commit": source_commit,
        "source_dirty": False,
        "surface_control_contract": CONTRACT_VERSION,
        "surface_control_sdk": SDK_VERSION,
        "profile_id": "xtouch.compact.standard.simulation",
        "profile_version": "1.1",
        "surface_plugins_revision": revision,
        "surface_plugins_files_sha256": shared_sources,
        "platform": os.uname().sysname,
        "architecture": os.uname().machine,
        "configuration": configuration,
        "files_sha256": files,
        "start_protocol": "token stdin pipe/private file, ready JSON stdout/file, POST /mcp on 127.0.0.1",
        "stop_protocol": "terminate the isolated process; no persistent user state",
    }
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def package(output, configuration="release"):
    if command("git", "status", "--porcelain"):
        raise RuntimeError("Commit the reviewed source before packaging")
    if output.exists():
        raise RuntimeError("Output already exists; choose a new delivery path")
    subprocess.run(["python3", "configs/surface_plugins_dependency.py", "verify"], cwd=ROOT, check=True)
    scratch = ROOT / "build" / "surface-simulator" / configuration
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
            "XTouchSurfaceSimulator",
        ],
        cwd=ROOT,
        check=True,
    )
    binary_directory = Path(
        command("swift", "build", "--configuration", configuration, "--scratch-path", str(scratch), "--show-bin-path")
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".surface-simulator-", dir=output.parent))
    try:
        shutil.copy2(binary_directory / "XTouchSurfaceSimulator", stage)
        stage_shared_files(stage)
        (stage / "control-contract.json").write_text(
            subprocess.check_output([str(stage / "XTouchSurfaceSimulator"), "--describe"], text=True)
        )
        write_manifest(stage, command("git", "rev-parse", "HEAD"), configuration)
        stage.rename(output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        help="new delivery directory (default: build/deliveries/xtouch-surface-simulator-<HEAD short SHA>)",
    )
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    print(package((args.output or default_output()).resolve(), args.configuration))


if __name__ == "__main__":
    main()
