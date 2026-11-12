#!/usr/bin/env python3
"""Build an independent software-only delivery with hashes and exact source pins."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def package(output, configuration="release"):
    if command("git", "status", "--porcelain"):
        raise RuntimeError("Commit the reviewed source before packaging")
    if output.exists():
        raise RuntimeError("Output already exists; choose a new delivery path")
    subprocess.run(["python3", "configs/surface_plugins_dependency.py", "verify"], cwd=ROOT, check=True)
    scratch = ROOT / "build" / "surface-simulator" / configuration
    subprocess.run(["swift", "build", "--jobs", "2", "--configuration", configuration,
                    "--scratch-path", str(scratch), "--product", "XTouchSurfaceSimulator"], cwd=ROOT, check=True)
    binary_directory = Path(command("swift", "build", "--configuration", configuration,
                                    "--scratch-path", str(scratch), "--show-bin-path"))
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".surface-simulator-", dir=output.parent))
    try:
        shutil.copy2(binary_directory / "XTouchSurfaceSimulator", stage)
        shutil.copy2(ROOT / "LICENSE", stage)
        shutil.copy2(ROOT / "examples/surface_simulator/minimal_consumer.py", stage)
        shutil.copy2(ROOT / "docs/SURFACE_SIMULATOR.md", stage / "README.md")
        shutil.copy2(ROOT / "configs/surface_plugins.lock.json", stage)
        shared = ROOT / "build/dependencies/SurfacePlugins"
        shutil.copy2(shared / "docs/surface-control-tools.json", stage / "control-tools.json")
        shutil.copy2(shared / "fixtures/surface-control-software-v1.json", stage)
        sdk_source = ROOT / "Clients/Python/surface_control/__init__.py"
        with zipfile.ZipFile(stage / "surface-control-sdk-1.0.0.zip", "w", compression=zipfile.ZIP_DEFLATED) as sdk:
            sdk.write(sdk_source, "surface_control/__init__.py")
        (stage / "examples").mkdir()
        for name in ("pipe_surface_trial.py", "surface_roundtrip.py"):
            shutil.copy2(ROOT / "Clients/Python/examples" / name, stage / "examples" / name)
        shutil.copy2(ROOT / "Clients/Python/SOURCE.json", stage / "surface-control-sdk-source.json")
        (stage / "control-contract.json").write_text(subprocess.check_output(
            [str(stage / "XTouchSurfaceSimulator"), "--describe"], text=True))
        files = {str(path.relative_to(stage)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(stage.rglob("*")) if path.is_file()}
        manifest = {"schema_version": 1, "product": "XTouchSurfaceSimulator", "source": "simulation",
            "source_commit": command("git", "rev-parse", "HEAD"), "source_dirty": False,
            "surface_control_contract": "1.0", "surface_control_sdk": "1.0.0",
            "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())["revision"],
            "platform": os.uname().sysname, "architecture": os.uname().machine,
            "configuration": configuration, "files_sha256": files,
            "start_protocol": "token stdin/file, ready JSON stdout/file, POST /mcp on 127.0.0.1",
            "stop_protocol": "terminate the isolated process; no persistent user state"}
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        stage.rename(output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    print(package(args.output.resolve(), args.configuration))


if __name__ == "__main__":
    main()
