"""Frozen common fields and a motor audit that never passes another device."""

import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path

from tools.audit_motor_safety import CaptureError, audit, review_capture

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests/Fixtures/Capture"


class CaptureInterchangeTests(unittest.TestCase):
    def test_frozen_samples_have_complete_contiguous_envelopes(self):
        for name in ("xtouch-sample.jsonl", "bcr-sample.jsonl"):
            data = (FIXTURES / name).read_bytes()
            self.assertTrue(data.endswith(b"\n"))
            rows = [json.loads(line) for line in data.splitlines()]
            self.assertEqual(rows[0]["kind"], "capture-start")
            self.assertEqual(rows[0]["schemaVersion"], 1)
            self.assertEqual(rows[-1]["kind"], "capture-end")
            events = rows[1:-1]
            self.assertEqual([event["sequence"] for event in events], list(range(1, len(events) + 1)))
            self.assertEqual(rows[-1]["eventCount"], len(events))
        provenance = json.loads((FIXTURES / "provenance.json").read_text())["bcr-sample.jsonl"]
        self.assertEqual(provenance["sha256"], hashlib.sha256((FIXTURES / "bcr-sample.jsonl").read_bytes()).hexdigest())
        self.assertIn(provenance["kind"], ("copied-bcr-fixture", "handwritten-placeholder"))
        if provenance["kind"] == "copied-bcr-fixture":
            self.assertRegex(provenance["commit"], r"^[0-9a-f]{40}$")
        else:
            self.assertIsNone(provenance["commit"])
            self.assertIn("replace", provenance["note"])

    def test_foreign_device_audit_is_not_applicable_and_cli_never_exits_pass(self):
        path = FIXTURES / "bcr-sample.jsonl"
        data = path.read_bytes()
        review = review_capture(data)
        self.assertEqual(review["assessment"], "not-applicable")
        self.assertIs(review["evidenceSufficient"], False)
        self.assertEqual(review["deviceModel"], "BCR2000")
        with self.assertRaises(CaptureError):
            audit(data)  # Existing strict Compact audit remains strict.
        result = subprocess.run(
            [sys.executable, "tools/audit_motor_safety.py", str(path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(json.loads(result.stdout)["assessment"], "not-applicable")
