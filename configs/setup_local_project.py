#!/usr/bin/env python3
"""Prepare locked dependencies and validate the Swift package and FreeCM commands."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings
from configs.build_environment import (
    ensure_local_build_environment,
    use_build_environment,
)
from configs.build_paths import build_path
from configs.control_surface_kit_dependency import LAYOUT as KIT_LAYOUT
from configs.control_surface_kit_dependency import ensure_dependency as ensure_control_surface_kit
from configs.managed_git_dependency import DependencyError, _git, _owned
from configs.surface_plugins_dependency import LAYOUT as SURFACE_LAYOUT
from configs.surface_plugins_dependency import ensure_dependency
from configs.validate_repo_commands import main as validate_commands


def write_phase_report(destination: Path, report: dict) -> None:
    """Publish a diagnostic once, without replacing an earlier report."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write((json.dumps(report, indent=2, sort_keys=True) + "\n").encode())
        os.link(temporary, destination, follow_symlinks=False)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(*, phase_report: str | None = None, scratch_path: str | None = None) -> int:
    # A failed reconfiguration must not leave a successful setup marker behind.
    marker = build_path(REPO_ROOT, "configured.json")
    marker.unlink(missing_ok=True)
    destination = None
    if phase_report is not None:
        if not phase_report.startswith("build/"):
            raise ValueError("Phase report must be a new file under build/")
        destination = build_path(REPO_ROOT, str(Path(phase_report).relative_to("build")))
        if destination.exists() or destination.is_symlink():
            raise ValueError("Phase report already exists")
    command = ["swift", "package", "dump-package"]
    if scratch_path is not None:
        if not scratch_path.startswith("build/"):
            raise ValueError("Explicit scratch must be under build/")
        scratch = build_path(REPO_ROOT, str(Path(scratch_path).relative_to("build")))
        command = ["swift", "package", "--scratch-path", str(scratch), "--manifest-cache", "local", "dump-package"]
    report = {
        "schema_version": 1,
        "phases": [],
        "platform": platform.system(),
        "architecture": platform.machine(),
        "manifest_argv": command,
    }

    def phase(name, body):
        if destination is None:
            return body()
        start = time.monotonic()
        record = {"name": name, "exit": 1}
        try:
            result = body()
            record["exit"] = 0
            return result
        except Exception as error:
            record["error_type"] = type(error).__name__
            raise
        finally:
            record["seconds"] = time.monotonic() - start
            report["phases"].append(record)

    def identity():
        dependencies = {}
        for name, lock in (("SurfacePlugins", "surface_plugins"), ("ControlSurfaceKit", "control_surface_kit")):
            checkout = build_path(REPO_ROOT, "dependencies/" + name)
            spec = json.loads((REPO_ROOT / "configs" / (lock + ".lock.json")).read_text())
            item = {"locked_revision": spec["revision"], "exists": checkout.is_dir()}
            if checkout.is_dir() and not checkout.is_symlink():
                try:
                    owned = _owned(
                        checkout, dict(os.environ), SURFACE_LAYOUT if name == "SurfacePlugins" else KIT_LAYOUT
                    )
                except DependencyError as error:
                    raise ValueError("Unsafe diagnostic dependency namespace") from error
                stat = checkout.stat()
                item.update(
                    inode=stat.st_ino,
                    device=stat.st_dev,
                    head=owned["revision"],
                    shallow=_git(checkout, "rev-parse", "--is-shallow-repository") == "true",
                    clean=True,
                )
            dependencies[name] = item
        return {
            "head": _git(REPO_ROOT, "rev-parse", "HEAD"),
            "dirty": bool(_git(REPO_ROOT, "status", "--porcelain")),
            "dependencies": dependencies,
        }

    result = 1
    try:
        if destination is not None:
            report["identity_before"] = phase("diagnostic_identity_before", identity)
        phase("ensure_local_build_environment", lambda: ensure_local_build_environment(REPO_ROOT))
        with use_build_environment(REPO_ROOT):
            settings = phase("load_app_build_settings", lambda: load_app_build_settings(REPO_ROOT))
            validation = phase("validate_commands", lambda: validate_commands([str(REPO_ROOT)]))
            if validation:
                if destination is not None:
                    report["phases"][-1]["exit"] = validation
                return 1
            phase("surface_plugins_ensure", lambda: ensure_dependency(REPO_ROOT))
            phase("control_surface_kit_ensure", lambda: ensure_control_surface_kit(REPO_ROOT))
            phase("dump_package", lambda: subprocess.run(command, cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL))
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(json.dumps({"schema_version": 1, "app_build": settings}, indent=2) + "\n")
        if destination is not None:
            report["identity_after"] = phase("diagnostic_identity_after", identity)
        result = 0
    finally:
        if result != 0:
            marker.unlink(missing_ok=True)
        if destination is not None:
            report["exit"] = result
            try:
                write_phase_report(destination, report)
            except Exception:
                marker.unlink(missing_ok=True)
                raise
    print("XTouchCompactDev local configuration is ready.")
    return 0


if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--phase-report")
        parser.add_argument("--scratch-path")
        args = parser.parse_args()
        raise SystemExit(main(phase_report=args.phase_report, scratch_path=args.scratch_path))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
