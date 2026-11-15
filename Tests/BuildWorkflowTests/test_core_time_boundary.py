"""The pure value core accepts time; real clock and I/O waiting belong in host adapters."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REAL_TIME = re.compile(
    r"\bDate\s*\(\s*\)|\bDate\s*\.(?:now|init)\b|ProcessInfo\.processInfo\.systemUptime|\b(?:Task|Thread)\.sleep\b|\b(?:ContinuousClock|SuspendingClock)\s*\("
)


class CoreTimeBoundaryTests(unittest.TestCase):
    def test_value_core_never_reads_real_time_or_sleeps(self):
        for path in sorted((ROOT / "Sources/XTouchCompactCore").glob("*.swift")):
            with self.subTest(source=path.name):
                self.assertIsNone(REAL_TIME.search(path.read_text()), path.name)
