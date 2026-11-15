"""Real hardware-service process with a local test-only MIDI adapter; never CoreMIDI."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "build/dependencies/SurfacePlugins/clients/python"))
from surface_control import Client, EventCursor, SurfaceError

# Resolved at import: the service runs with each test's temporary directory as cwd.
BINARY = Path(os.environ.get("XTOUCH_HARDWARE_BINARY", ROOT / ".build/debug/XTouchSurfaceHardware")).resolve()


class RunningHardware:
    def __init__(self, directory, feedback=True, fake=True):
        self.directory = Path(directory)
        self.script = self.directory / "midi.json"
        self.report = self.directory / "output.json"
        self.rows = [{"connected": True}]
        self.script.write_text(json.dumps(self.rows))
        self.token = secrets.token_hex(32)
        self.ready_file = self.directory / "ready.json"
        args = [str(BINARY), "--receive-channel", "2", "--light-protocol", "observed114", "--token-stdin", "--surface-instance-id", "hardware.test", "--ready-file", str(self.ready_file)]
        if feedback:
            args.append("--allow-surface-feedback")
        env = dict(os.environ)
        env.pop("XTOUCH_HARDWARE_TEST_SCRIPT", None)
        env.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
        if fake:
            env.update(XTOUCH_HARDWARE_TEST_SCRIPT=str(self.script), XTOUCH_HARDWARE_TEST_REPORT=str(self.report))
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, cwd=directory)
        self.process.stdin.write(self.token + "\n")
        self.process.stdin.close()
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError(self.process.stderr.read())
        self.ready = json.loads(line)
        self.client = Client(self.ready["url"], self.token, "hardware.test", accepted_sources=("hardware",))
        self.discover()

    def discover(self):
        return self.client.discover(versions=("1.4",), profiles=("xtouch.compact.standard.hardware",), profile_versions=("1.4",))

    def append(self, *rows):
        self.rows.extend(rows)
        staging = self.script.with_suffix(".next")
        staging.write_text(json.dumps(self.rows))
        staging.replace(self.script)
        # Reading snapshot processes the buffered local adapter before servicing HTTP.
        return self.raw("surface_control_snapshot", {"instance_id": "hardware.test"})["structuredContent"]

    def raw(self, name, arguments):
        data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}).encode()
        req = urllib.request.Request(self.ready["url"], data, {"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as response:
            return json.load(response)["result"]

    def output(self):
        return json.loads(self.report.read_text())

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


@unittest.skipUnless(sys.platform == "darwin", "XTouchSurfaceHardware target is macOS-only")
class HardwareHTTPTests(unittest.TestCase):
    def test_hardware_lifecycle_touch_cursor_display_and_sdk_optin(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningHardware(directory)
            try:
                self.assertTrue(host.ready["test_only"])
                self.assertEqual(host.client.snapshot()["inputs"], {})
                self.assertEqual(host.output()["sent_count"], 0)
                with self.assertRaises(SurfaceError) as caught:
                    Client(host.ready["url"], host.token, "hardware.test").discover()
                self.assertEqual(caught.exception.code, "unsupported_contract")
                cursor = EventCursor(host.client)
                cursor.bootstrap(host.client.snapshot())
                snapshot = host.append({"bytes": [176, 28, 100]}, {"bytes": [176, 111, 127]}, {"bytes": [176, 111, 0]}, {"bytes": [176, 37, 64]}, {"bytes": [144, 71, 127]}, {"bytes": [128, 71, 0]})
                self.assertEqual(snapshot["inputs"]["b.fader.1"], 100)
                self.assertFalse(snapshot["inputs"]["b.touch.1"])
                events = cursor.poll()
                self.assertEqual(len(events), 6)
                self.assertTrue(all(e["event"]["source"] == e["event"]["origin"] == "hardware" for e in events))
                host.client.feedback("b.button.2", "indicator", "on")
                host.client.feedback("b.encoder.1", "value", 13)
                words = [int(word, 16) for word in host.output()["words"]]
                self.assertEqual(len(words), 3)
                self.assertTrue(all(((word >> 16) & 0xF0) != 0xC0 and not (((word >> 16) & 0xF0) == 0xB0 and 1 <= ((word >> 8) & 127) <= 9) for word in words))
                before = host.client.snapshot()
                old_expected = dict(host.client.expected)
                host.append({"connected": False})
                with self.assertRaises(SurfaceError) as caught:
                    cursor.poll()
                self.assertEqual(caught.exception.code, "stale_epoch")
                self.assertEqual(host.raw("surface_control_events", {"instance_id": "hardware.test", "epoch": old_expected["epoch"], "after_sequence": "0", "limit": 100})["structuredContent"]["code"], "stale_epoch")
                host.append({"bytes": [176, 28, 10]}, {"connected": True})
                host.client = Client(host.ready["url"], host.token, "hardware.test", accepted_sources=("hardware",))
                host.discover()
                snapshot = host.client.snapshot()
                self.assertEqual(snapshot["inputs"], {})
                self.assertEqual(snapshot["link"]["state"], "connected")
                self.assertEqual(snapshot["discovery"]["latest_sequence"], "0")
                self.assertNotEqual(old_expected["epoch"], host.client.expected["epoch"])
                self.assertEqual(host.output()["sent_count"], 3)
                self.assertNotEqual(before["inputs"], snapshot["inputs"])
            finally:
                host.close()
            self.assertFalse(host.ready_file.exists())

    def test_invalidating_error_recovers_with_a_new_epoch_after_backoff(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningHardware(directory)
            try:
                first = dict(host.client.expected)
                host.script.write_text("{not json")
                broken = host.raw("surface_control_snapshot", {"instance_id": "hardware.test"})["structuredContent"]
                self.assertEqual(broken["link"]["state"], "disconnected")
                self.assertNotEqual(broken["discovery"]["expected"]["epoch"], first["epoch"])
                staging = host.script.with_suffix(".next")
                staging.write_text(json.dumps(host.rows))
                staging.replace(host.script)
                deadline = time.monotonic() + 5
                while True:
                    current = host.raw("surface_control_snapshot", {"instance_id": "hardware.test"})["structuredContent"]
                    if current["link"]["state"] == "connected" or time.monotonic() > deadline:
                        break
                    time.sleep(0.05)
                # Re-established on its own as a new epoch: no stale identity, values unknown, nothing sent.
                self.assertEqual(current["link"]["state"], "connected")
                self.assertNotEqual(current["discovery"]["expected"]["epoch"], broken["discovery"]["expected"]["epoch"])
                self.assertEqual(current["inputs"], {})
                self.assertEqual(host.output()["sent_count"], 0)
            finally:
                host.close()

    def test_fixed_remote_rejections_and_failure_are_atomic(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningHardware(directory)
            try:
                expected = host.client.expected
                before = host.client.snapshot()
                probes = [("input", {"expected": expected, "expected_sequence": "0", "control_id": "b.fader.1", "encoding": "scalar", "value": 127}, "permission_denied"), ("renew", {"expected": expected, "control_id": "b.button.1", "hold_s": 1}, "unsupported_hold"), ("reset", {"expected": expected, "expected_sequence": "0"}, "unsupported_tool")]
                for tool, args, code in probes:
                    result = host.raw("surface_control_" + tool, args)
                    self.assertTrue(result["isError"])
                    self.assertEqual(result["structuredContent"]["code"], code)
                after = host.client.snapshot()
                self.assertEqual(before["inputs"], after["inputs"])
                self.assertEqual(after["discovery"]["latest_sequence"], "0")
                host.append({"bytes": [176, 28, 64]}, {"fail_send": True})
                before = host.client.snapshot()
                with self.assertRaises(SurfaceError) as caught:
                    host.client.feedback("b.button.2", "indicator", "on")
                self.assertEqual(caught.exception.code, "transport_error")
                after = host.client.snapshot()
                self.assertEqual(before["discovery"]["latest_sequence"], after["discovery"]["latest_sequence"])
                self.assertEqual(after["feedback"], {})
                self.assertEqual(host.output()["sent_count"], 0)
            finally:
                host.close()

    def test_permission_off_and_fader_feedback_produce_zero_output(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningHardware(directory, feedback=False)
            try:
                host.append({"bytes": [176, 28, 64]})
                for control, kind, value, code in [("b.button.2", "indicator", "on", "permission_denied"), ("b.fader.1", "value", 64, "unsupported_feedback")]:
                    with self.assertRaises(SurfaceError) as caught:
                        host.client.feedback(control, kind, value)
                    self.assertEqual(caught.exception.code, code)
                self.assertEqual(host.output()["sent_count"], 0)
            finally:
                host.close()

    def test_describe_and_missing_configuration_never_open_midi(self):
        result = subprocess.run([str(BINARY), "--describe", "--receive-channel", "2", "--light-protocol", "observed114"], capture_output=True, text=True, check=True)
        document = json.loads(result.stdout)
        self.assertEqual(document["discovery"]["contract_version"], "1.4")
        self.assertEqual(len(document["discovery"]["profile"]["controls"]), 182)
        for args in [("--describe",), ("--describe", "--receive-channel", "2")]:
            result = subprocess.run([str(BINARY), *args], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(os.environ.get("XTOUCH_RUN_HARDWARE_ACCEPTANCE") == "1", "Requires explicitly attended physical controller; disabled in E development")
    def test_attended_real_coremidi_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningHardware(directory, feedback=False, fake=False)
            try:
                self.assertFalse(host.ready["test_only"])
                self.assertEqual(host.client.snapshot()["link"]["state"], "connected")
            finally:
                host.close()
