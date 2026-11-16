"""Independent mac validation must gate native execution without serializing compilation."""

import contextlib
import io
import json
import os
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from configs import ci_validation_gate

ROOT = Path(__file__).resolve().parents[2]
START = datetime(2026, 11, 16, tzinfo=timezone.utc)
SHA = "a" * 40


class ValidationGateTests(unittest.TestCase):
    def run_record(self):
        return {
            "id": 10,
            "run_attempt": 2,
            "head_sha": SHA,
            "created_at": START.isoformat(),
            "repository": {"full_name": "org/repo"},
        }

    def job(self, name, status="completed", conclusion="success"):
        return {
            "id": 1 if name == "app-macos" else 2,
            "name": name,
            "run_id": 10,
            "run_attempt": 2,
            "head_sha": SHA,
            "status": status,
            "conclusion": conclusion,
        }

    def wait(self, fetch, **kwargs):
        return ci_validation_gate.wait_for_validation(
            fetch,
            repository="org/repo",
            run_id=10,
            attempt=2,
            consumer="app-macos",
            producer="validation-macos",
            now=kwargs.pop("now", lambda: START),
            **kwargs,
        )

    def fixture(self, run=None, producer=None, extra=()):
        def fetch(suffix, timeout):
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 15)
            if not suffix:
                return self.run_record() if run is None else run
            self.assertEqual(suffix, "/attempts/2/jobs?per_page=100")
            jobs = [self.job("app-macos"), self.job("validation-macos") if producer is None else producer, *extra]
            return {"jobs": jobs, "total_count": len(jobs)}

        return fetch

    def test_exact_success_is_required_and_has_no_wait(self):
        result = self.wait(self.fixture(), pause=lambda _: self.fail("success must not wait"))
        self.assertEqual(result["head_sha"], SHA)
        self.assertEqual(result["validation_job_id"], 2)
        self.assertEqual(result["validation_conclusion"], "success")

    def test_wrong_run_attempt_repository_and_sha_are_never_substituted(self):
        for field, value in [("id", 11), ("run_attempt", 1), ("repository", {"full_name": "other/repo"})]:
            with self.subTest(field=field), self.assertRaisesRegex(RuntimeError, "identity mismatch"):
                self.wait(self.fixture(run={**self.run_record(), field: value}))
        for field, value in [("run_id", 11), ("run_attempt", 1), ("head_sha", "b" * 40)]:
            with self.subTest(field=field), self.assertRaisesRegex(RuntimeError, "SHA mismatch"):
                self.wait(self.fixture(producer={**self.job("validation-macos"), field: value}))

    def test_missing_wrong_or_duplicate_job_name_fails_closed(self):
        for name in ["validation-macos-other", "validation-macos (old)"]:
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "exactly one"):
                self.wait(self.fixture(producer=self.job(name)))
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            self.wait(self.fixture(extra=[self.job("validation-macos")]))
        with self.assertRaisesRegex(RuntimeError, "partial job page"):
            self.wait(
                lambda suffix, timeout: (
                    self.run_record() if not suffix else {"jobs": [self.job("app-macos")], "total_count": 3}
                )
            )

    def test_validation_failure_cancellation_skip_and_neutral_do_not_run_products(self):
        for conclusion in ["failure", "cancelled", "skipped", "neutral", "timed_out"]:
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(RuntimeError, "producer failed"):
                self.wait(
                    self.fixture(producer=self.job("validation-macos", conclusion=conclusion)),
                    pause=lambda _: self.fail("failure must not wait"),
                )

    def test_pending_validation_waits_then_uses_same_attempt_success(self):
        clock = [START]
        polls, pauses = [], []

        def fetch(suffix, timeout):
            if not suffix:
                return self.run_record()
            polls.append(suffix)
            producer = self.job("validation-macos") if pauses else self.job("validation-macos", "in_progress", None)
            return {"jobs": [self.job("app-macos", "in_progress", None), producer]}

        def pause(seconds):
            pauses.append(seconds)
            clock[0] += timedelta(seconds=seconds)

        result = self.wait(fetch, now=lambda: clock[0], pause=pause)
        self.assertEqual(pauses, [2])
        self.assertEqual(result["wait_seconds"], 2)
        self.assertTrue(all(path == "/attempts/2/jobs?per_page=100" for path in polls))

    def test_a_new_attempt_while_waiting_cannot_reuse_old_success(self):
        first = [True]

        def fetch(suffix, timeout):
            if not suffix:
                if first[0]:
                    first[0] = False
                    return self.run_record()
                return {**self.run_record(), "run_attempt": 3}
            return {"jobs": [self.job("app-macos"), self.job("validation-macos", "in_progress", None)]}

        with self.assertRaisesRegex(RuntimeError, "changed while waiting"):
            self.wait(fetch, pause=lambda _: None)

    def test_wait_never_extends_created_at_deadline_for_late_consumer(self):
        with self.assertRaisesRegex(RuntimeError, "300s budget"):
            self.wait(
                self.fixture(), now=lambda: START + timedelta(seconds=300), pause=lambda _: self.fail("must not wait")
            )
        clock = [START + timedelta(seconds=299)]

        def pause(seconds):
            self.assertEqual(seconds, 1)
            clock[0] += timedelta(seconds=seconds)

        with self.assertRaisesRegex(RuntimeError, "300s budget"):
            self.wait(
                self.fixture(producer=self.job("validation-macos", "in_progress", None)),
                now=lambda: clock[0],
                pause=pause,
            )

    def test_cli_checkout_binding_and_credentials_stay_in_memory(self):
        environment = {
            "GITHUB_REPOSITORY": "org/repo",
            "GITHUB_RUN_ID": "10",
            "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_JOB": "app-macos",
            "GITHUB_SHA": "c" * 40,
            "GH_TOKEN": "must-not-appear-in-output",
        }
        responses = [
            io.BytesIO(json.dumps(self.run_record()).encode()),
            io.BytesIO(json.dumps({"jobs": [self.job("app-macos"), self.job("validation-macos")]}).encode()),
        ]
        # A PR merge checkout may differ from API head SHA; both job API SHAs still exactly match.
        run = self.run_record()
        run["created_at"] = datetime.now(timezone.utc).isoformat()
        responses[0] = io.BytesIO(json.dumps(run).encode())
        output = io.StringIO()
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(ci_validation_gate.subprocess, "check_output", return_value=environment["GITHUB_SHA"] + "\n"),
            patch.object(ci_validation_gate.urllib.request, "urlopen", side_effect=responses) as network,
            contextlib.redirect_stdout(output),
        ):
            ci_validation_gate.main([])
        self.assertNotIn(environment["GH_TOKEN"], output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["checkout_sha"], environment["GITHUB_SHA"])
        self.assertEqual(network.call_count, 2)
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(ci_validation_gate.subprocess, "check_output", return_value="different"),
            patch.object(ci_validation_gate.urllib.request, "urlopen") as network,
            self.assertRaisesRegex(RuntimeError, "checkout SHA"),
        ):
            ci_validation_gate.main([])
        network.assert_not_called()

    def test_workflow_moves_complete_validation_and_gates_before_every_native_execution(self):
        text = (ROOT / ".github/workflows/ci.yml").read_text()
        validation = text.split("  validation-macos:", 1)[1].split("  app-macos:", 1)[0]
        app = text.split("  app-macos:", 1)[1]
        self.assertNotIn("needs:", app)
        for block, runner in [(validation, "macos-26-intel"), (app, "macos-26")]:
            self.assertIn("runs-on: " + runner + "\n", block)
            self.assertIn("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer", block)
            self.assertIn("ref: ${{ github.sha }}", block)
            self.assertIn("python3 configs/setup_local_project.py", block)
        self.assertIn("dependencies-${{ runner.os }}-${{ runner.arch }}-", validation)
        self.assertNotIn("path: build/swiftpm", validation)
        self.assertIn("brew install swiftformat ruff", validation)
        self.assertIn("python3 configs/format_repo.py --check", validation)
        self.assertIn("python3 configs/check_host_layers.py", validation)
        self.assertIn("python3 -B configs/run_python_workflow_tests.py --suite workflow", validation)
        self.assertNotIn("--suite workflow", app)
        self.assertNotIn("brew install", app)
        gate = app.index("python3 configs/ci_validation_gate.py --producer validation-macos")
        self.assertLess(app.index("swift build --build-path build/swiftpm --build-tests"), gate)
        for command in [
            "swift test --build-path build/swiftpm --skip-build",
            "--pattern test_hardware_service.py",
            "--pattern test_hardware_offline_diagnostics.py",
            "python3 configs/macos_workflow.py build",
            "--startup-smoke",
        ]:
            self.assertGreater(app.index(command), gate)
        # Position alone is insufficient: no native step may override the gate's failure.
        native = app[app.index("Require exact validation success before native execution") :]
        self.assertNotIn("continue-on-error:", native)
        before_artifacts = native.split("# Release ZIP/DMG", 1)[0]
        self.assertNotIn("if: always()", before_artifacts)
        self.assertIn("actions: read", text)
        self.assertEqual(text.count("--post-reserve-seconds 20"), 3)
