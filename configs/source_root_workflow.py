#!/usr/bin/env python3
"""FreeCM adapter: local setup and explicit cleanup; no external source roots."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.setup_local_project import main as setup_main

CLEAN_TARGETS = ("configured.json", "swiftpm", "app", "package")


def clean_build(*, dry_run: bool = False) -> None:
    build = REPO_ROOT / "build"
    if build.is_symlink() or (build.exists() and not build.is_dir()):
        raise ValueError("Refusing to clean a symlinked or non-directory build path.")
    for name in CLEAN_TARGETS:
        path = build / name
        if not path.exists() and not path.is_symlink():
            continue
        print(f"{'Would remove' if dry_run else 'Removing'} build/{name}")
        if not dry_run:
            if path.is_symlink() or path.is_file():
                path.unlink()
            else:
                shutil.rmtree(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--init", action="store_true", help="Compatibility with older FreeCM versions.")
    action.add_argument("--initlock", action="store_true")
    action.add_argument("--initrepo", action="store_true")
    action.add_argument("--update", action="store_true")
    action.add_argument("--cleanbuild", action="store_true")
    parser.add_argument("--quiet", action="store_true", help="Accepted for plugin invocations.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.dry_run and not args.cleanbuild:
        parser.error("--dry-run requires --cleanbuild")
    if args.cleanbuild:
        clean_build(dry_run=args.dry_run)
        return 0
    if args.initlock:
        print("No external source roots; no dependency lock is required.")
        return 0
    return setup_main()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
