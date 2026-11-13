import json
import unittest
from pathlib import Path

from test_motor_safety_audit import module as audit_engine


class CaptureReviewFixtureTests(unittest.TestCase):
    def test_shared_native_and_cli_expected_reports(self):
        path = Path(__file__).resolve().parents[1] / "Fixtures/CaptureReview/cases.json"
        for fixture in json.loads(path.read_text()):
            with self.subTest(case=fixture["name"]):
                report = audit_engine.audit(fixture["jsonl"].encode())
                for key in ("sha256", "qualification", "releaseWindowMeaning"):
                    report.pop(key)
                self.assertEqual(report, fixture["expected"])
