#!/usr/bin/env python3
"""Join complete lint and complete setup before the production-layer preflight check.

No validation can be disabled. Source-tool resolution is checked before and after
Homebrew; every subprocess keeps its own original argv, output and exit status.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs.build_paths import build_path

XCODE = "/Applications/Xcode_26.6.app/Contents/Developer"
SETUP = [
    "python3",
    "configs/setup_local_project.py",
    "--scratch-path",
    "build/swiftpm",
    "--phase-report",
    "build/ci-verification/setup/preflight.json",
]
INSTALL = ["brew", "install", "swiftformat", "ruff"]
LINT = ["python3", "configs/format_repo.py", "--check"]


def tool_identity(environ):
    if environ.get("DEVELOPER_DIR") != XCODE:
        raise ValueError("Preflight requires the fixed Xcode developer directory")
    records = {"developer_dir": XCODE}
    for name, command in (
        ("swift", ["swift", "--version"]),
        ("git", ["git", "--version"]),
        ("python3", ["python3", "--version"]),
    ):
        selected = shutil.which(name, path=environ.get("PATH"))
        if selected is None:
            raise ValueError("Missing required source tool: " + name)
        executable = Path(selected).resolve(strict=True)
        version = subprocess.run(command, env=environ, capture_output=True, text=True, check=True)
        records[name] = {
            "selected": selected,
            "resolved": str(executable),
            "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "version": (version.stdout + version.stderr).strip(),
        }
    actual = subprocess.run(
        ["/usr/bin/xcrun", "--find", "swift"], env=environ, capture_output=True, text=True, check=True
    ).stdout.strip()
    actual_path = Path(actual).resolve(strict=True)
    if not actual_path.is_relative_to(Path(XCODE).resolve(strict=True)):
        raise ValueError("Swift does not belong to the fixed Xcode")
    if records["swift"]["resolved"] != "/usr/bin/swift" and records["swift"]["resolved"] != str(actual_path):
        raise ValueError("PATH selects a different Swift toolchain")
    records["xcode_swift"] = {
        "resolved": str(actual_path),
        "sha256": hashlib.sha256(actual_path.read_bytes()).hexdigest(),
    }
    return records


def run_parallel(root=ROOT, environ=None, *, identity_reader=tool_identity, command_runner=subprocess.run):
    root = Path(root).resolve()
    environ = dict(os.environ if environ is None else environ)
    directory = build_path(root, "ci-verification/preflight")
    directory.mkdir(parents=True, exist_ok=False)
    report = {"schema_version": 1, "commands": {}, "identity_before": None, "identity_after": None}
    start = time.monotonic()
    failure = True

    def run(name, argv, output):
        began = time.monotonic()
        try:
            result = command_runner(argv, cwd=root, env=environ, stdout=output, stderr=subprocess.STDOUT, check=False)
            return {"name": name, "argv": argv, "exit": result.returncode, "seconds": time.monotonic() - began}
        except Exception as error:
            return {
                "name": name,
                "argv": argv,
                "exit": 1,
                "seconds": time.monotonic() - began,
                "error_type": type(error).__name__,
            }

    def setup():
        with (directory / "setup.log").open("wb") as output:
            return [run("setup", SETUP, output)]

    def lint():
        with (directory / "lint.log").open("wb") as output:
            installed = run("install", INSTALL, output)
            if installed["exit"] != 0:
                return [installed]
            return [installed, run("lint", LINT, output)]

    try:
        report["identity_before"] = identity_reader(environ)
        with ThreadPoolExecutor(max_workers=2) as executor:
            setup_future = executor.submit(setup)
            lint_future = executor.submit(lint)
            for name, future in (("setup", setup_future), ("lint", lint_future)):
                try:
                    report["commands"][name] = future.result()
                except Exception as error:
                    report["commands"][name] = [
                        {"name": name, "exit": 1, "error_type": type(error).__name__, "command_started": False}
                    ]
        report["identity_after"] = identity_reader(environ)
        if report["identity_before"] != report["identity_after"]:
            raise ValueError("Homebrew changed Swift/Git/Python tool identity")
        failure = any(item["exit"] != 0 for rows in report["commands"].values() for item in rows)
    except Exception as error:
        report["error_type"] = type(error).__name__
        failure = True
    finally:
        report["seconds"] = time.monotonic() - start
        report["exit"] = int(failure)
        (directory / "preflight.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        for name in ("setup.log", "lint.log"):
            path = directory / name
            if path.is_file():
                sys.stdout.buffer.write(path.read_bytes())
        sys.stdout.flush()
    return int(failure)


def main():
    try:
        return run_parallel()
    except (OSError, ValueError) as error:
        print("Preflight preparation failed: " + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
