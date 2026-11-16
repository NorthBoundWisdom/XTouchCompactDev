"""Same BCR job-summary vocabulary and warm/cold policy; no GitHub network access in tests."""

import contextlib
import io
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from configs import ci_job_budget

ROOT = Path(__file__).resolve().parents[2]


class CIJobBudgetTests(unittest.TestCase):
    def job(self):
        return {
            "name": "core-linux",
            "started_at": "2026-01-01T00:10:00Z",
            "steps": [
                {
                    "name": "Build | tests",
                    "status": "completed",
                    "conclusion": "success",
                    "started_at": "2026-01-01T00:10:01Z",
                    "completed_at": "2026-01-01T00:10:06Z",
                },
                {"name": "Report", "status": "in_progress", "started_at": "2026-01-01T00:10:06Z"},
            ],
        }

    def test_warm_budget_uses_job_not_queue_and_boundary_is_strict(self):
        start = datetime(2026, 1, 1, 0, 10, tzinfo=timezone.utc)
        run = {"id": 1, "created_at": "2026-01-01T00:00:00Z"}
        body, failed = ci_job_budget.report(run, self.job(), "matched-key", start + timedelta(seconds=300))
        self.assertFalse(failed)
        self.assertIn("## Job wall time and warm-cache 300s budget", body)
        self.assertIn("300.0s job wall time", body)
        self.assertIn("900.0s since run creation", body)
        self.assertIn("| Build / tests | success | 5.0 |", body)
        self.assertTrue(ci_job_budget.report(run, self.job(), "matched-key", start + timedelta(seconds=300.1))[1])

    def test_cold_bootstrap_is_reported_but_not_failed(self):
        now = datetime(2026, 1, 1, 1, tzinfo=timezone.utc)
        body, failed = ci_job_budget.report({"id": 2, "created_at": "2026-01-01T00:00:00Z"}, self.job(), "", now)
        self.assertFalse(failed)
        self.assertIn("cold build cache", body)
        self.assertIn("Cold-cache bootstrap measured; warm-cache budget exempt.", body)
        self.assertIn("Restored build key: `none`", body)

    def test_matrix_job_is_selected_explicitly_and_summary_has_no_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            summary = Path(temporary) / "summary.md"
            run = {"id": 3, "created_at": "2026-01-01T00:00:00Z"}
            target = {**self.job(), "name": "package-smoke (macos-26)"}
            responses = [io.BytesIO(json.dumps(run).encode()), io.BytesIO(json.dumps({"jobs": [target]}).encode())]
            env = {
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_RUN_ID": "3",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_JOB": "package-smoke",
                "CI_JOB_NAME": target["name"],
                "GH_TOKEN": "never-print-this-token",
                "GITHUB_STEP_SUMMARY": str(summary),
            }
            with (
                patch.dict(os.environ, env, clear=True),
                patch("sys.argv", ["ci_job_budget.py"]),
                patch.object(ci_job_budget.urllib.request, "urlopen", side_effect=responses),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                ci_job_budget.main()
            text = summary.read_text()
            self.assertIn(target["name"], text)
            self.assertNotIn(env["GH_TOKEN"], text)

    def test_workflows_report_always_and_save_after_compile_before_tests(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        package = (ROOT / ".github/workflows/package.yml").read_text()
        self.assertEqual(ci.count("name: Report wall time and enforce warm-cache 300s budget"), 2)
        self.assertEqual(package.count("name: Report wall time and enforce warm-cache 300s budget"), 2)
        for text in (ci, package):
            self.assertIn("outputs.cache-matched-key", text)
            self.assertIn("steps.compile.outcome == 'success'", text)
            self.assertIn("cold_build:", text)
            self.assertNotIn("if: success() && github.event_name", text)
        self.assertLess(ci.index("Save compiled portable cache"), ci.index("swift test --skip-build"))
        self.assertLess(
            ci.index("Save compiled native cache"), ci.index("swift test --build-path build/swiftpm --skip-build")
        )
        self.assertIn("CI_JOB_NAME: package-smoke (${{ matrix.os }})", package)
