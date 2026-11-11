#!/usr/bin/env python3
"""Fail explicitly if the modern CI lane accidentally selects an older Swift compiler."""

import re
import subprocess


def validate_swift_version(output: str, minimum: tuple[int, int] = (6, 2)) -> tuple[int, int, int]:
    match = re.search(r"\bSwift version (\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise ValueError("Unable to identify the Swift compiler version.")
    version = tuple(int(part or 0) for part in match.groups())
    if version[:2] < minimum:
        raise ValueError(f"Modern CI requires Swift {minimum[0]}.{minimum[1]}+, got {version}.")
    return version


def main() -> None:
    result = subprocess.run(["swift", "--version"], check=True, capture_output=True, text=True)
    print(result.stdout, end="", flush=True)
    validate_swift_version(result.stdout)


if __name__ == "__main__":
    main()
