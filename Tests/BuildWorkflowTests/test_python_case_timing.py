"""Per-case evidence preserves unittest outcomes, fixture scope and discovery selection."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from configs import run_python_workflow_tests as timing


class PythonCaseTimingTests(unittest.TestCase):
    def test_suite_and_pattern_selection(self):
        self.assertEqual(timing.parse_arguments([]).suite, "workflow")
        args = timing.parse_arguments(["--suite", "simulator", "--pattern", "test_hardware_service.py"])
        self.assertEqual((args.suite, args.pattern), ("simulator", "test_hardware_service.py"))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            timing.parse_arguments(["--suite", "invalid"])

    def test_failures_keep_nonzero_status_and_all_case_evidence_after_teardown(self):
        events = []

        class Cases(unittest.TestCase):
            def tearDown(self):
                events.append(self._testMethodName)

            def test_success(self):
                pass

            def test_failure(self):
                self.fail("expected probe failure")

        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()) as output:
            path = Path(temporary) / "evidence.json"
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(Cases)
            self.assertEqual(timing.run_suite(suite, path, stream=io.StringIO()), 1)
            records = json.loads(path.read_text())
        self.assertEqual(len(records), 2)
        self.assertEqual(set(events), {"test_success", "test_failure"})
        self.assertEqual({row["test"].rsplit(".", 1)[-1] for row in records}, set(events))
        self.assertTrue(all(row["seconds"] >= 0 for row in records))
        self.assertIn("Slowest workflow cases:", output.getvalue())
