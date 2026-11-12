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


def route(generation=0):
    return dict(generation=generation, connectedInput={"id": 1}, connectedOutput={"id": 1})


def event(raw=None, **fields):
    row = dict(
        kind="event",
        source="hardware",
        hardwareMode=True,
        hostLayer="a",
        transmitChannel=1,
        ignored=False,
        rawMIDI1Bytes=raw,
    )
    row.update(fields)
    if row.get("direction") == "IN":
        row.setdefault("delivery", "received")
    return row


def capture(events, complete=True, session=None):
    if session is None:
        session = dict(
            hardwareMode=True,
            configuredTransmitChannel=1,
            connectionGeneration=0,
            connectedInput={"id": 1},
            connectedOutput={"id": 1},
        )
    rows = [dict(kind="capture-start", schemaVersion=1, session=session)]
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
                    motor(1, hardwareMode=False, source="agent"),
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
        result = module.audit(
            capture([touch(1, False), touch(2, True), event(connection=route(1)), motor(1), motor(2)])
        )
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
                (capture([motor(1)]), 3),
                (capture([], complete=False), 3),
            ]:
                path.write_bytes(data)
                result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(path.read_bytes(), data)

    def test_hardware_safety_touch_while_mocking_survives_entering_hardware(self):
        held = dict(touch(1, True, "b"), hardwareMode=False)
        mock_release = dict(touch(1, False), hardwareMode=False, source="mock")
        result = module.audit(capture([held, mock_release, motor(1)]))
        self.assertEqual(result["motorWhileTouched"], [3])
        self.assertEqual(result["motorWithUnknownLayer"], [3])
        self.assertEqual(result["assessment"], "violations")

    def test_old_release_is_unknown_after_reconnection(self):
        result = module.audit(capture([touch(1, False), event(connection=route(1)), motor(1)]))
        self.assertEqual(result["motorWithUnknownTouch"], [3])
        self.assertEqual(result["assessment"], "inconclusive")
        self.assertFalse(result["evidenceSufficient"])

    def test_identical_known_connection_snapshot_does_not_erase_layer_evidence(self):
        result = module.audit(capture([touch(1, False, "b"), event(connection=route()), motor(1)]))
        self.assertEqual(result["motorDuringLayerMismatch"], [3])
        self.assertEqual(result["stateBoundaries"], [])
        self.assertEqual(result["releaseWindows"][0]["motorCount"], 1)

    def test_transmit_channel_change_expires_release_but_retains_held_latches(self):
        rows = [
            touch(1, False),
            touch(2, True),
            event(transmitChannel=5),
            motor(1, transmitChannel=5),
            motor(2, transmitChannel=5),
        ]
        result = module.audit(capture(rows))
        self.assertEqual(result["motorWithUnknownTouch"], [4])
        self.assertEqual(result["motorWhileTouched"], [5])
        self.assertEqual(result["stateBoundaries"], [{"sequence": 3, "reason": "transmit-channel-change"}])
        self.assertEqual(result["releaseWindows"][0]["motorCount"], 0)

    def test_mode_switch_closes_release_windows_and_invalidates_layer_evidence(self):
        rows = [touch(1, False), event(hardwareMode=False, source="application"), motor(1)]
        result = module.audit(capture(rows))
        self.assertEqual(result["motorWithUnknownTouch"], [3])
        self.assertEqual(result["motorWithUnknownLayer"], [3])
        self.assertEqual(result["releaseWindows"][0]["endReason"], "hardware-mode-change")
        self.assertEqual(result["releaseWindows"][0]["motorCount"], 0)

    def test_layer_assertion_requires_touch_evidence_for_all_nine_faders(self):
        command = event([0xC1, 0], direction="OUT", delivery="sent")
        unknown = module.audit(capture([touch(1, False), command]))
        self.assertEqual(unknown["layerAssertionWithUnknownTouch"], [2])
        self.assertEqual(unknown["assessment"], "inconclusive")
        known = module.audit(capture([touch(index, False) for index in range(1, 10)] + [command]))
        self.assertTrue(known["evidenceSufficient"])
        self.assertEqual(known["assessment"], "no-recorded-violations")
        self.assertEqual(known["layerAssertionWithUnknownTouch"], [])

    def test_null_route_is_unknown_instead_of_an_invented_connection(self):
        session = dict(
            hardwareMode=True,
            configuredTransmitChannel=1,
            connectionGeneration=None,
            connectedInput=None,
            connectedOutput=None,
        )
        rows = [touch(1, False), motor(1), event([0xC1, 0], direction="OUT", delivery="sent")]
        result = module.audit(capture(rows, session=session))
        self.assertEqual(result["motorWithUnknownRoute"], [2])
        self.assertEqual(result["layerAssertionWithUnknownRoute"], [3])
        self.assertEqual(result["assessment"], "inconclusive")

    def test_missing_or_contradictory_metadata_is_rejected_instead_of_skipped(self):
        invalid_rows = [
            dict(motor(1), hardwareMode=None),
            dict(motor(1), hardwareMode=1),
            dict(motor(1), ignored=None),
            dict(motor(1), transmitChannel=True),
            dict(motor(1), source="unknown"),
            dict(motor(1), direction=None),
            dict(motor(1), hardwareMode=False),
            dict(touch(1, True), delivery=None),
            event(connection={}),
            event(connection=dict(route(), generation=True)),
        ]
        missing = motor(1)
        del missing["hardwareMode"]
        invalid_rows.append(missing)
        for row in invalid_rows:
            with self.subTest(row=row), self.assertRaises(module.CaptureError):
                module.audit(capture([row]))
        valid = capture([])
        for invalid in (
            valid.replace(b'"schemaVersion": 1', b'"schemaVersion": true'),
            valid.replace(b'"eventCount": 0', b'"eventCount": false'),
            valid.replace(b'"connectionGeneration": 0', b'"connectionGeneration": true'),
            valid.replace(b'"hardwareMode": true', b'"hardwareMode": "true"'),
        ):
            with self.subTest(invalid=invalid), self.assertRaises(module.CaptureError):
                module.audit(invalid)

    def test_cli_inconclusive_result_is_machine_readable_and_preserves_original(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.jsonl"
            data = capture([motor(1)])
            path.write_bytes(data)
            result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True)
            self.assertEqual(result.returncode, 3)
            report = json.loads(result.stdout)
            self.assertEqual(report["assessment"], "inconclusive")
            self.assertFalse(report["evidenceSufficient"])
            self.assertEqual(path.read_bytes(), data)
