"""CI layer configuration: preserve argv, fail closed, partition every test."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from configs import ci_swift_test_layer as layer


class CITestLayerTests(unittest.TestCase):
    def test_actual_entry_point_adds_only_the_approved_skip_and_preserves_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "step.sh"
            script.write_text(" ".join(layer.BASE_ARGV) + "\n")
            with (
                patch.dict(os.environ, {"XTOUCH_CI_TEST_LAYER": "regression"}),
                patch.object(layer.subprocess, "call", return_value=7) as run,
            ):
                self.assertEqual(layer.main([str(script)]), 7)
            run.assert_called_once_with(layer.BASE_ARGV + ["--skip", layer.PROOF_PATTERN])

    def test_unexpected_command_or_layer_is_rejected_without_execution(self):
        for command, selected in [
            ("echo hidden", "regression"),
            (" ".join(layer.BASE_ARGV) + "; true", "regression"),
            (" ".join(layer.BASE_ARGV), "full"),
        ]:
            with (
                self.subTest(command=command, selected=selected),
                self.assertRaises(ValueError),
            ):
                layer.effective_argv(command, selected)

    def test_inventory_partition_is_exact_and_nearby_names_remain_regressions(self):
        tests = [
            "OtherModule.ControllerRegressionAcceptance/differentProofName()",
            layer.PROOF_TEST,
            "XTouchCompactAppTests.ControllerRegressionAcceptance/independentSchedulerReplaysEveryOtherStep()",
        ]
        self.assertEqual(
            layer.verify_partition(tests),
            {
                "original_count": 3,
                "regression_count": 2,
                "full_proof_count": 1,
                "full_proof": [layer.PROOF_TEST],
                "intersection_count": 0,
                "union_equals_original": True,
            },
        )
        for invalid in [
            [],
            [layer.PROOF_TEST] * 2,
            tests[:1],
            [
                layer.PROOF_TEST,
                layer.PROOF_TEST.replace("XTouchCompactAppTests", "OtherModule"),
            ],
            [layer.PROOF_TEST, layer.PROOF_TEST.replace("()", "Extra()")],
        ]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                layer.verify_partition(invalid)

    def test_workflows_declare_both_layers_and_verify_real_complete_inventory(self):
        root = Path(__file__).resolve().parents[2]
        normal = (root / ".github/workflows/ci.yml").read_text()
        proof = (root / ".github/workflows/full-proof.yml").read_text()
        self.assertIn("XTOUCH_CI_TEST_LAYER: regression", normal)
        self.assertEqual(normal.count("shell: python3 configs/ci_swift_test_layer.py {0}"), 1)
        for workflow in [normal, proof]:
            self.assertIn(
                "swift test --build-path build/swiftpm --skip-build --manifest-cache local list",
                workflow,
            )
            self.assertIn("python3 configs/ci_swift_test_layer.py --verify-list", workflow)
        self.assertIn("--filter '" + layer.PROOF_PATTERN + "'", proof)
        for required in [
            "workflow_dispatch:",
            "schedule:",
            "timeout-minutes: 30",
            "'configs/**'",
            "'Sources/**'",
            "'Tests/**'",
        ]:
            self.assertIn(required, proof)
