#!/usr/bin/env python3
"""Format/lint development sources using SwiftFormat and Ruff (developer tools only)."""

import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
commands = [
    ["swiftformat", "Sources", "Tests", "--config", "configs/.swiftformat", *(["--lint"] if args.check else [])],
    [
        "ruff",
        "check",
        "--config",
        "configs/ruff.toml",
        "configs",
        "Tests/BuildWorkflowTests",
        "tools",
        "--exclude",
        "configs/_vendor",
        *([] if args.check else ["--fix"]),
    ],
    [
        "ruff",
        "format",
        "--config",
        "configs/ruff.toml",
        "configs",
        "Tests/BuildWorkflowTests",
        "tools",
        "--exclude",
        "configs/_vendor",
        *(["--check"] if args.check else []),
    ],
]
for command in commands:
    subprocess.run(command, cwd=ROOT, check=True)
