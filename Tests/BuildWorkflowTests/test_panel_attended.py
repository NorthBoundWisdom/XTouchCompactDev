"""Panel field additions are preparation only; no automatic real-device sending path."""

import unittest

from configs.hardware_attended import panel_supplement


class PanelAttendedTests(unittest.TestCase):
    def test_budget_stage_keeps_physical_ceiling_unknown_and_requires_fresh_confirmation(self):
        document = panel_supplement()
        self.assertIn("not executed", document["status"])
        step = document["steps"][0]
        self.assertEqual(step["id"], "H-C-BUDGET")
        self.assertTrue(step["sends_to_device"])
        self.assertFalse(step["moves_motors"])
        self.assertIn("just confirmed", step["confirm_before"])
        self.assertIsNone(step["automatic_command"])
        self.assertIn("unknown", step["result"])
        self.assertTrue(any("Transport acceptance is not device receipt" in value for value in step["procedure"]))

    def test_demo_stage_is_display_only_and_requires_local_layer_evidence(self):
        step = panel_supplement()["steps"][1]
        self.assertEqual(step["id"], "H-C-DEMO")
        self.assertTrue(step["sends_to_device"])
        self.assertFalse(step["moves_motors"])
        self.assertIsNone(step["automatic_command"])
        self.assertIn("no physical demonstration", step["result"])
        self.assertTrue(any("trusted layer-A" in value for value in step["prerequisites"]))
        self.assertTrue(any("freshness turns off" in value for value in step["procedure"]))
