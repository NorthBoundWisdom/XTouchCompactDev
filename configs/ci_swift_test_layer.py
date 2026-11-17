#!/usr/bin/env python3
"""Explicit Actions shell for the unchanged native regression command only.

The manifest-cache policy remains in the workflow's original command. This
entry point prints and appends the one approved full-proof exclusion, then
returns Swift's exact exit status. It never executes arbitrary shell content.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

BASE_ARGV = ["swift", "test", "--build-path", "build/swiftpm", "--skip-build", "--manifest-cache", "local"]
PROOF_TEST = "XTouchCompactAppTests.ControllerRegressionAcceptance/independentNativeAndTypedOwnersMatchEveryApplicableControllerStep()"
PROOF_PATTERN = r"independentNativeAndTypedOwnersMatchEveryApplicableControllerStep"


def effective_argv(script: str, layer: str) -> list[str]:
    if layer != "regression":
        raise ValueError("This entry point requires the explicit regression layer")
    argv = shlex.split(script)
    if argv != BASE_ARGV:
        raise ValueError("Only the original native Swift test command is accepted")
    return argv + ["--skip", PROOF_PATTERN]


def verify_partition(specifiers: list[str]) -> dict:
    if not specifiers or len(specifiers) != len(set(specifiers)):
        raise ValueError("Test inventory must be nonempty and unique")
    proof = [test for test in specifiers if re.search(PROOF_PATTERN, test)]
    if proof != [PROOF_TEST]:
        raise ValueError("The complete proof must select exactly the approved original method")
    regression = [test for test in specifiers if not re.search(PROOF_PATTERN, test)]
    if set(regression).intersection(proof) or set(regression + proof) != set(specifiers):
        raise ValueError("The two layers must partition the full original inventory")
    return {
        "original_count": len(specifiers),
        "regression_count": len(regression),
        "full_proof_count": len(proof),
        "full_proof": proof,
        "intersection_count": 0,
        "union_equals_original": True,
    }


def main(argv=None) -> int:
    args = sys.argv[1:] if argv is None else argv
    try:
        if len(args) == 2 and args[0] == "--verify-list":
            print(json.dumps(verify_partition(Path(args[1]).read_text().splitlines()), sort_keys=True))
            return 0
        if len(args) != 1:
            raise ValueError("Expected one Actions script path or --verify-list PATH")
        command = effective_argv(Path(args[0]).read_text(), os.environ.get("XTOUCH_CI_TEST_LAYER", ""))
        print("Explicit regression layer effective argv: " + json.dumps(command), flush=True)
        return subprocess.call(command)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
