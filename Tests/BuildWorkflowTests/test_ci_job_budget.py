"""Same BCR job-summary vocabulary and warm/cold policy; no GitHub network access in tests."""

import contextlib
import io
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from configs import ci_job_budget

ROOT = Path(__file__).resolve().parents[2]


class CIJobBudgetTests(unittest.TestCase):
    def run_record(self):
        return {"id": 1, "created_at": "2026-11-16T00:00:00Z"}

    def job(self):
        return {
            "name": "core-linux",
            "started_at": "2026-11-16T00:00:00Z",
            "steps": [
                {
                    "name": "Compile",
                    "status": "completed",
                    "conclusion": "success",
                    "started_at": "2026-11-16T00:00:10Z",
                    "completed_at": "2026-11-16T00:02:00Z",
                },
                {"name": "Report", "status": "in_progress", "started_at": "2026-11-16T00:02:00Z"},
            ],
        }

    def test_cold_cache_whole_run_over_budget_fails(self):
        text, failed = ci_job_budget.report(
            self.run_record(), self.job(), "", datetime(2026, 11, 16, 0, 5, 1, tzinfo=timezone.utc)
        )
        self.assertTrue(failed)
        self.assertIn("cold build cache", text)
        self.assertIn("301.0s", text)
        self.assertIn("| Compile | success | 110.0 |", text)

    def test_restored_prefix_is_warm_and_over_budget_fails(self):
        text, failed = ci_job_budget.report(
            self.run_record(),
            self.job(),
            "swiftpm-mac-tool-previous-sha",
            datetime(2026, 11, 16, 0, 5, 1, tzinfo=timezone.utc),
        )
        self.assertTrue(failed)
        self.assertIn("301.0s", text)
        self.assertIn("Compile | success | 110.0", text)

    def test_exact_budget_boundary_passes(self):
        _, failed = ci_job_budget.report(
            self.run_record(), self.job(), "key", datetime(2026, 11, 16, 0, 5, tzinfo=timezone.utc)
        )
        self.assertFalse(failed)

    def test_queue_and_late_job_cannot_bypass_whole_run_budget(self):
        job = self.job()
        job["started_at"] = "2026-11-16T00:04:50Z"
        text, failed = ci_job_budget.report(
            self.run_record(), job, "", datetime(2026, 11, 16, 0, 5, 1, tzinfo=timezone.utc)
        )
        self.assertTrue(failed)
        self.assertIn("11.0s job wall time", text)
        self.assertIn("301.0s since run creation", text)
        self.assertIn("post-job cleanup", text)

    def test_cold_cache_exact_boundary_still_passes_without_exemption(self):
        text, failed = ci_job_budget.report(
            self.run_record(), self.job(), "", datetime(2026, 11, 16, 0, 5, tzinfo=timezone.utc)
        )
        self.assertFalse(failed)
        self.assertIn("no cold-cache exemption", text)

    def test_matrix_job_is_selected_explicitly_and_summary_has_no_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            summary = Path(temporary) / "summary.md"
            run = {"id": 3, "created_at": datetime.now(timezone.utc).isoformat()}
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
        self.assertEqual(ci.count("name: Report whole-run wall time and enforce 300s budget"), 2)
        self.assertEqual(package.count("name: Report whole-run wall time and enforce 300s budget"), 2)
        for text in (ci, package):
            self.assertEqual(text.count("timeout-minutes: 20"), 2)
            self.assertIn("outputs.cache-matched-key", text)
            self.assertIn("steps.compile.outcome == 'success'", text)
            self.assertIn("cold_build:", text)
            self.assertNotIn("if: success() && github.event_name", text)
        self.assertLess(ci.index("Save compiled portable cache"), ci.index("swift test --skip-build"))
        self.assertLess(
            ci.index("Save compiled native cache"), ci.index("swift test --build-path build/swiftpm --skip-build")
        )
        self.assertIn("CI_JOB_NAME: package-smoke (${{ matrix.os }})", package)
