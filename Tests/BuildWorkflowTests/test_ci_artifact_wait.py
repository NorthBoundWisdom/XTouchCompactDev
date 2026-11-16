"""Early-started consumers never fall back to another attempt or bypass the whole-run budget."""

import unittest
from datetime import datetime, timezone

from configs.ci_artifact_wait import wait_for_artifacts


class ArtifactWaitTests(unittest.TestCase):
    def test_only_exact_unexpired_attempt_artifacts_unblock_consumers(self):
        queries, pauses = [], []
        name = "slice-attempt-2"

        def fetch(suffix):
            queries.append(suffix)
            if suffix == "":
                return {"created_at": "2026-01-01T00:00:00Z", "run_attempt": 2}
            if suffix.startswith("/attempts/"):
                return {"jobs": [{"name": "compile-slices (arm64)", "conclusion": None}]}
            return {
                "artifacts": (
                    [{"name": "slice-attempt-1", "expired": False}, {"name": name, "expired": True}]
                    if not pauses
                    else [{"name": name, "expired": False}]
                )
            }

        wait_for_artifacts(
            fetch,
            [name],
            ["compile-slices"],
            now=lambda: datetime(2026, 1, 1, tzinfo=timezone.utc),
            pause=pauses.append,
        )
        self.assertEqual(pauses, [2])
        self.assertIn("/attempts/2/jobs?per_page=100", queries)

    def test_cold_or_warm_wait_cannot_extend_the_run_deadline(self):
        def fetch(suffix):
            self.assertEqual(suffix, "")
            return {"created_at": "2026-01-01T00:00:00Z"}

        with self.assertRaisesRegex(RuntimeError, "300s budget"):
            wait_for_artifacts(
                fetch, ["slice-attempt-1"], [], now=lambda: datetime(2026, 1, 1, 0, 5, tzinfo=timezone.utc)
            )

    def test_failed_matrix_producer_fails_consumers_without_waiting(self):
        def fetch(suffix):
            if not suffix:
                return {"created_at": "2026-01-01T00:00:00Z", "run_attempt": 1}
            if suffix.startswith("/artifacts"):
                return {"artifacts": []}
            return {"jobs": [{"name": "compile-slices (arm64)", "conclusion": "failure"}]}

        with self.assertRaisesRegex(RuntimeError, "producer failed"):
            wait_for_artifacts(
                fetch,
                ["slice-attempt-1"],
                ["compile-slices"],
                now=lambda: datetime(2026, 1, 1, tzinfo=timezone.utc),
                pause=lambda _: self.fail("must not wait"),
            )
