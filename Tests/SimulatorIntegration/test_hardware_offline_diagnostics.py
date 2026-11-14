"""Device-access-disabled production binary: real HTTP, no fake MIDI and no device calls."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "build/dependencies/SurfacePlugins/clients/python"))
from configs.verify_hardware_http import RunningOfflineHardware
from surface_control import Client, SurfaceError

BINARY = Path(os.environ.get("XTOUCH_HARDWARE_BINARY", ROOT / ".build/debug/XTouchSurfaceHardware"))


@unittest.skipUnless(sys.platform == "darwin", "XTouchSurfaceHardware target is macOS-only")
class OfflineHardwareHTTPTests(unittest.TestCase):
    def test_disabled_device_access_has_unknown_inputs_and_fixed_remote_rejections(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningOfflineHardware(BINARY, directory)
            try:
                client = Client(host.ready["url"], host.token, host.instance, accepted_sources=("hardware",))
                discovered = client.discover(versions=("1.4",))
                self.assertEqual(discovered["source"], "hardware")
                expected = dict(client.expected)
                before = client.snapshot()
                self.assertEqual(before["inputs"], {})
                self.assertEqual(before["link"], {"state": "disconnected"})
                probes = [("input", {"expected": expected, "expected_sequence": "0", "control_id": "b.fader.1", "encoding": "scalar", "value": 127}, "permission_denied"), ("renew", {"expected": expected, "control_id": "b.button.1", "hold_s": 1}, "unsupported_hold"), ("reset", {"expected": expected, "expected_sequence": "0"}, "unsupported_tool"), ("feedback", {"expected": expected, "control_id": "b.encoder.1", "kind": "value", "value": 13}, "invalid_transition")]
                for tool, arguments, code in probes:
                    with self.subTest(tool=tool):
                        result = host.tool("surface_control_" + tool, arguments)
                        self.assertTrue(result["isError"])
                        self.assertEqual(result["structuredContent"]["code"], code)
                self.assertEqual(host.tool("surface_control_device_access", {"device_access": "enabled"})["structuredContent"]["code"], "unsupported_tool")
                for _ in range(3):
                    after = client.snapshot()
                    self.assertEqual(after["inputs"], {})
                    self.assertEqual(after["feedback"], {})
                    self.assertEqual(after["link"], {"state": "disconnected"})
                    self.assertEqual(after["discovery"]["expected"], before["discovery"]["expected"])
                    self.assertEqual(after["discovery"]["latest_sequence"], "0")
                page = client.call("surface_control_events", {"instance_id": host.instance, "epoch": expected["epoch"], "after_sequence": "0", "limit": 100})
                self.assertEqual(page["events"], [])
                self.assertEqual(page["link"], {"state": "disconnected"})
                with self.assertRaises(SurfaceError) as caught:
                    Client(host.ready["url"], host.token, host.instance).discover()
                self.assertEqual(caught.exception.code, "unsupported_contract")
            finally:
                host.close()
            self.assertFalse(host.ready_path.exists())
            evidence = host.audit()
            self.assertGreater(evidence["request_records"], 0)
            self.assertTrue(all(value == 0 for value in evidence["device_io"].values()))
            reports = ROOT / "build/e-extension"
            reports.mkdir(parents=True, exist_ok=True)
            (reports / "process-disabled-device-access.json").write_text(json.dumps(evidence, indent=2) + "\n")

    def test_disabled_auth_origin_and_sigint_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningOfflineHardware(BINARY, directory)
            try:
                for token, origin, status in [("invalid-token", None, 401), (host.token, "https://example.invalid", 403)]:
                    with self.subTest(status=status):
                        with self.assertRaises(urllib.error.HTTPError) as caught:
                            host.tool("surface_control_discover", token=token, origin=origin)
                        self.assertEqual(caught.exception.code, status)
                        caught.exception.close()
            finally:
                host.close(signal.SIGINT)
            self.assertFalse(host.ready_path.exists())
            self.assertEqual(host.audit()["cleanup_records"], 1)

    def test_disabled_access_rejects_script_environment_before_any_factory(self):
        with tempfile.TemporaryDirectory() as directory:
            for key in ("XTOUCH_HARDWARE_TEST_SCRIPT", "XTOUCH_HARDWARE_TEST_REPORT"):
                with self.subTest(environment=key):
                    environment = dict(os.environ)
                    environment.pop("XTOUCH_HARDWARE_TEST_SCRIPT", None)
                    environment.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
                    environment[key] = str(Path(directory) / "must-not-open")
                    result = subprocess.run([str(BINARY), "--device-access", "disabled", "--receive-channel", "2", "--light-protocol", "observed114", "--describe"], env=environment, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("disabledRejectsTestInjection", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse((Path(directory) / "must-not-open").exists())

    def test_describe_identifies_disabled_and_rejects_runtime_selection_ambiguity(self):
        arguments = [str(BINARY), "--device-access", "disabled", "--receive-channel", "2", "--light-protocol", "observed114", "--describe"]
        result = subprocess.run(arguments, capture_output=True, text=True, check=True)
        description = json.loads(result.stdout)
        self.assertEqual(description["device_access"], "disabled")
        self.assertIs(description["diagnostic_only"], True)
        self.assertEqual(description["discovery"]["source"], "hardware")
        ambiguous = subprocess.run([*arguments, "--device-access", "enabled"], capture_output=True, text=True)
        self.assertNotEqual(ambiguous.returncode, 0)
        self.assertEqual(ambiguous.stdout, "")
        help_output = subprocess.check_output([str(BINARY), "--help"], text=True)
        self.assertIn("--device-access enabled|disabled", help_output)
        self.assertIn("no physical qualification", help_output)
