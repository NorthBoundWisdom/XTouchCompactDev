"""A timing capture must prove the actual payload order, not just matching packet counts."""

import copy
import unittest

from configs.measure_display_budget import validate_receipts


class DisplayMeasurementValidationTests(unittest.TestCase):
    def examples(self):
        requests = [{"kind": "value", "index": 2, "value": 7, "result": {"isError": False}}]
        receipts = [
            {"kind": "style", "index": 2, "word": "20B10B00", "send_index": 1},
            {"kind": "value", "index": 2, "word": "20B11B07", "send_index": 2},
        ]
        return requests, receipts

    def test_wrong_payload_cannot_pass_with_correct_kind_and_target(self):
        requests, receipts = self.examples()
        self.assertEqual(validate_receipts(requests, receipts), [])
        receipts[1]["word"] = "20B11B08"
        self.assertTrue(validate_receipts(requests, receipts))

    def test_missing_or_nonconsecutive_receipts_are_rejected(self):
        requests, receipts = self.examples()
        self.assertTrue(validate_receipts(requests, receipts[:1]))
        modified = copy.deepcopy(receipts)
        modified[1]["send_index"] = 3
        self.assertTrue(validate_receipts(requests, modified))

    def test_motor_packet_is_rejected_even_with_expected_value_and_typed_labels(self):
        requests, receipts = self.examples()
        receipts[1]["word"] = "20B10107"
        self.assertTrue(any("Forbidden output" in error for error in validate_receipts(requests, receipts)))
