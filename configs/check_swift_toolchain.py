#!/usr/bin/env python3
"""Fail explicitly if macOS CI accidentally selects an older Swift compiler."""

import argparse
import hashlib
import re
import subprocess
from pathlib import Path


def validate_swift_version(output: str, minimum: tuple[int, int] = (6, 2)) -> tuple[int, int, int]:
    match = re.search(r"\bSwift version (\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise ValueError("Unable to identify the Swift compiler version.")
    version = tuple(int(part or 0) for part in match.groups())
    if version[:2] < minimum:
        raise ValueError(f"macOS CI requires Swift {minimum[0]}.{minimum[1]}+, got {version}.")
    return version


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-env", type=Path)
    args = parser.parse_args()
    result = subprocess.run(["swift", "--version"], check=True, capture_output=True)
    output = result.stdout.decode()
    print(output, end="", flush=True)
    validate_swift_version(output)
    if args.github_env is not None:
        digest = hashlib.sha256(result.stdout + result.stderr).hexdigest()[:16]
        with args.github_env.open("a", encoding="utf-8") as stream:
            stream.write(f"SWIFT_ID={digest}\n")


if __name__ == "__main__":
    main()
