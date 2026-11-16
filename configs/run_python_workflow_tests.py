#!/usr/bin/env python3
"""Run the unchanged workflow suite with per-case wall-time evidence."""

from __future__ import annotations

import argparse
import json
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class TimedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.durations = []

    def startTest(self, test):
        self.started = time.perf_counter()
        super().startTest(test)

    def stopTest(self, test):
        self.durations.append({"test": test.id(), "seconds": time.perf_counter() - self.started})
        super().stopTest(test)


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=("workflow", "simulator"), default="workflow")
    parser.add_argument("--pattern", default="test*.py")
    return parser.parse_args(argv)


def run_suite(suite, output, stream=None):
    result = unittest.TextTestRunner(verbosity=2, resultclass=TimedResult, stream=stream).run(suite)
    records = sorted(result.durations, key=lambda row: -row["seconds"])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, indent=2) + "\n")
    print("Slowest workflow cases:")
    for row in records[:20]:
        print(f"{row['seconds']:.3f}s {row['test']}")
    return int(not result.wasSuccessful())


def main(argv=None):
    args = parse_arguments(argv)
    directory = "BuildWorkflowTests" if args.suite == "workflow" else "SimulatorIntegration"
    suite = unittest.defaultTestLoader.discover(str(ROOT / "Tests" / directory), pattern=args.pattern)
    # Separate reports for the two native hardware selections, plus the complete Linux suite.
    name = args.pattern.replace("*", "all").replace("/", "_")
    output = ROOT / "build/ci-verification/tests" / f"python-{args.suite}-{name}-case-times.json"
    return run_suite(suite, output)


if __name__ == "__main__":
    raise SystemExit(main())
