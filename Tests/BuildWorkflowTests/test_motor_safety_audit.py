import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/audit_motor_safety.py"
spec = importlib.util.spec_from_file_location("motor_audit", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def event(raw=None, **fields):
    return dict(
        kind="event",
        source="hardware",
        hardwareMode=True,
        hostLayer="a",
        transmitChannel=1,
        rawMIDI1Bytes=raw,
        **fields,
    )


def capture(events, complete=True):
    rows = [dict(kind="capture-start", schemaVersion=1)]
    rows += [dict(row, sequence=index) for index, row in enumerate(events, 1)]
    if complete:
        rows.append(dict(kind="capture-end", eventCount=len(events)))
    return ("\n".join(json.dumps(row) for row in rows) + "\n").encode()


def touch(index, pressed, layer="a"):
    return event([0xB0, (100 if layer == "a" else 110) + index, 127 if pressed else 0], direction="IN")


def motor(index, delivery="sent", **fields):
    row = event([0xB1, index, 60], direction="OUT", delivery=delivery)
    row.update(fields)
    return row


class MotorSafetyAuditTests(unittest.TestCase):
    def test_touch_and_layer_mismatch_use_physical_identity_on_both_layers(self):
        for index in range(1, 10):
            for layer in ("a", "b"):
                result = module.audit(capture([touch(index, True, layer), motor(index), motor(index % 9 + 1)]))
                self.assertEqual(result["motorWhileTouched"], [2])
                self.assertEqual(result["motorDuringLayerMismatch"], [2, 3] if layer == "b" else [])

    def test_release_windows_count_zero_one_many_and_ignore_repeated_release(self):
        rows = [
            touch(1, True),
            touch(1, False),
            motor(1),
            motor(2),
            touch(1, False),
            touch(1, True),
            touch(1, False),
            touch(1, True),
            touch(1, False),
            motor(1),
            motor(1),
        ]
        result = module.audit(capture(rows))
        self.assertEqual([window["motorCount"] for window in result["releaseWindows"]], [1, 0, 2])
        self.assertEqual(result["releaseWindows"][0]["motorSequences"], [3])
        self.assertEqual(result["motorWhileTouched"], [])

    def test_only_sent_hardware_outputs_count_including_agent(self):
        result = module.audit(
            capture(
                [
                    touch(1, True),
                    motor(1, "suppressed"),
                    motor(1, "failed"),
                    motor(1, source="mock"),
                    motor(1, hardwareMode=False),
                    motor(1, source="agent"),
                ]
            )
        )
        self.assertEqual(result["motorWhileTouched"], [6])
        self.assertEqual(result["motorOutputs"], 1)

    def test_unknown_prefix_state_and_delivery_are_never_a_pass(self):
        result = module.audit(capture([motor(1), motor(1, None)], complete=False))
        self.assertFalse(result["complete"])
        self.assertEqual(result["motorWithUnknownTouch"], [1])
        self.assertEqual(result["motorWithUnknownLayer"], [1])
        self.assertEqual(result["outputsWithUnknownDelivery"], [2])

    def test_wrong_channel_and_ignored_inputs_do_not_establish_touch_or_layer(self):
        wrong = touch(1, True, "b")
        wrong["rawMIDI1Bytes"][0] = 0xB4
        ignored = dict(touch(1, True, "b"), ignored=True)
        result = module.audit(capture([wrong, ignored, motor(1)]))
        self.assertEqual(result["motorWithUnknownTouch"], [3])
        self.assertEqual(result["motorWithUnknownLayer"], [3])

    def test_sent_layer_assertion_clears_evidence_without_fabricating_observation(self):
        rows = [touch(1, True, "b"), event([0xC1, 0], direction="OUT", delivery="sent"), motor(1)]
        result = module.audit(capture(rows))
        self.assertEqual(result["layerAssertionWhileTouched"], [2])
        self.assertEqual(result["motorWhileTouched"], [3])
        self.assertEqual(result["motorWithUnknownLayer"], [3])
        self.assertEqual(result["motorDuringLayerMismatch"], [])

    def test_connection_closes_release_window_but_never_fabricates_release(self):
        result = module.audit(capture([touch(1, False), touch(2, True), event(connection={}), motor(1), motor(2)]))
        self.assertEqual(result["releaseWindows"][0]["motorCount"], 0)
        self.assertEqual(result["releaseWindows"][0]["endReason"], "connection-change")
        self.assertEqual(result["motorWhileTouched"], [5])
        self.assertEqual(result["motorWithUnknownLayer"], [4, 5])

    def test_rejects_corrupt_sequence_incomplete_line_and_invalid_midi(self):
        data = capture([motor(1)])
        for bad in (
            data[:-1],
            data.replace(b'"sequence": 1', b'"sequence": 2'),
            data + b"{}\n",
            capture([event([0xB0, 1], direction="IN")]),
            capture([event(direction="IN")]),
            b"[]\n",
        ):
            with self.subTest(bad=bad), self.assertRaises(module.CaptureError):
                module.audit(bad)

    def test_cli_is_read_only_and_has_distinct_violation_and_invalid_exit_codes(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "capture.jsonl"
            for data, code in [
                (capture([touch(1, True), motor(1)]), 1),
                (capture([touch(1, False)]), 0),
                (b"bad\n", 2),
            ]:
                path.write_bytes(data)
                result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(path.read_bytes(), data)
