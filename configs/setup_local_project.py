#!/usr/bin/env python3
"""Validate the local Swift package and FreeCM commands without downloads."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings
from configs.build_environment import ensure_local_build_environment, use_build_environment
from configs.validate_repo_commands import main as validate_commands


def main() -> int:
    # A failed reconfiguration must not leave a successful setup marker behind.
    marker = REPO_ROOT / "build/configured.json"
    marker.unlink(missing_ok=True)
    ensure_local_build_environment(REPO_ROOT)
    with use_build_environment(REPO_ROOT):
        settings = load_app_build_settings(REPO_ROOT)
        if validate_commands([str(REPO_ROOT)]):
            return 1
        subprocess.run(["swift", "package", "dump-package"], cwd=REPO_ROOT,
                       check=True, stdout=subprocess.DEVNULL)
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps({"schema_version": 1, "app_build": settings}, indent=2) + "\n")
    print("XTouchCompactDev local configuration is ready.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
