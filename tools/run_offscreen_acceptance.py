#!/usr/bin/env python3
"""Run local owned-PID AX acceptance. Requires a graphical macOS session and AX permission; never runs in CI."""

from __future__ import annotations

import argparse
import importlib
import json
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.native_ui import ManualRequired, MissingPermission, preflight

SUITES = {
    "n5": "verify_n5_ui",
    "organize": "verify_organize_ui",
    "offline": "verify_offline_ui",
    "panels": "verify_new_panels_ui",
}


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", *SUITES], default="all")
    parser.add_argument("--output", type=Path, default=ROOT / "build/ui-acceptance" / str(uuid.uuid4()))
    parser.add_argument("--binary", type=Path, help="already-built Debug executable; otherwise build once")
    args = parser.parse_args(argv)
    if not args.output.resolve().is_relative_to((ROOT / "build").resolve()):
        parser.error("--output must be under this repository's build/")
    return args


def main(argv=None):
    args = parse_arguments(argv)
    args.output.mkdir(parents=True, exist_ok=True)
    result = {"qualification": "offscreen-AX-only-not-operator-acceptance", "results": []}
    try:
        if sys.platform != "darwin":
            result["status"] = "missing-platform"
            result["reason"] = "Native UI acceptance requires macOS; no UI process was launched."
            return 77
        try:
            preflight()
        except MissingPermission as error:
            result["status"] = "missing-permission"
            result["reason"] = str(error)
            print(str(error))
            return 77
        binary = args.binary
        if binary is None:
            subprocess.run([sys.executable, "configs/setup_local_project.py"], cwd=ROOT, check=True)
            subprocess.run(["swift", "build", "--product", "XTouchCompactApp"], cwd=ROOT, check=True)
            directory = (
                subprocess.run(
                    ["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True, check=True
                )
                .stdout.strip()
                .splitlines()[-1]
            )
            binary = Path(directory) / "XTouchCompactApp"
        for suite in SUITES if args.suite == "all" else [args.suite]:
            module = importlib.import_module("tools." + SUITES[suite])
            try:
                rows = module.run(args.output / suite, binary.resolve())
            except MissingPermission as error:
                rows = [{"case": suite, "status": "missing-permission", "reason": str(error)}]
            except ManualRequired as error:
                rows = [{"case": suite, "status": "manual-required", "reason": str(error)}]
            except Exception as error:
                rows = [{"case": suite, "status": "failed", "reason": str(error)}]
            result["results"] += [{"script": SUITES[suite] + ".py", **row} for row in rows]
            if any(row["status"] == "missing-permission" for row in rows):
                result["status"] = "missing-permission"
                print(json.dumps(result, indent=2, ensure_ascii=False))
                return 77
        result["status"] = (
            "failed" if any(row["status"] == "failed" for row in result["results"]) else "completed-with-manual-items"
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return int(result["status"] == "failed")
    except subprocess.CalledProcessError:
        result["status"] = "build-failed"
        result["reason"] = "Acceptance build/helper preparation failed; no scenario is passed."
        print(result["reason"])
        return 1
    finally:
        (args.output / "summary.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        print("Offscreen evidence:", args.output)


if __name__ == "__main__":
    raise SystemExit(main())
