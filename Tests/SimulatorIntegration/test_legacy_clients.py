"""Frozen SDK version gates and old wire shapes against the real current host."""
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest

from test_http_simulator import ROOT, TOKEN, RunningSimulator


FROZEN_SDKS = {
    "1.1.0": ("4a00114", "1dcc3ce363c7d0b7db4a1c87d0c7827753987164e6c615b3306b00c51bcd7e85"),
    "1.2.0": ("54d2120", "75edcfcb26560fd18fa6f91277d6a4d2cd6468f18b680a0421416bf8390c1bc1"),
}


class LegacyClientsHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.host = RunningSimulator(self.temporary.name, "legacy.client")

    def tearDown(self):
        self.host.close()
        self.temporary.cleanup()

    def frozen_sdk_gate(self, version):
        commit, digest = FROZEN_SDKS[version]
        archive = ROOT / "build/deliveries" / ("xtouch-surface-simulator-" + commit) / ("surface-control-sdk-" + version + ".zip")
        if not archive.exists():
            self.skipTest("Frozen SDK " + version + " delivery zip is absent; old wire compatibility still runs")
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), digest)
        # A fresh interpreter imports exclusively from the verified frozen zip. Do not
        # change its allowlist, pass a fabricated host version, or import current SDK.
        script = """
import json, sys
sys.path.insert(0, sys.argv[1])
import surface_control
from surface_control import Client, SurfaceError
assert surface_control.__file__.startswith(sys.argv[1] + '/')
options = json.load(sys.stdin)
client = Client(options['url'], options['token'], 'legacy.client')
try:
    client.discover()
except SurfaceError as error:
    print(json.dumps({'code': error.code, 'module': surface_control.__file__}))
else:
    raise AssertionError('Frozen SDK unexpectedly accepted contract 1.3')
"""
        result = subprocess.run([sys.executable, "-B", "-c", script, str(archive)],
            input=json.dumps({"url": self.host.ready["url"], "token": TOKEN}),
            capture_output=True, text=True, cwd=self.temporary.name, timeout=10, check=True)
        self.assertEqual(json.loads(result.stdout)["code"], "unsupported_contract")
        self.assertEqual(self.host.snapshot()["latest_sequence"], "0")

    def test_frozen_sdk_1_1_0_reports_unsupported_contract(self):
        self.frozen_sdk_gate("1.1.0")

    def test_frozen_sdk_1_2_0_reports_unsupported_contract(self):
        self.frozen_sdk_gate("1.2.0")

    def legacy_wire_roundtrip(self, version):
        discovery = self.host.discover()
        self.assertEqual(discovery["contract_version"], "1.3")
        expected = discovery["expected"]
        self.assertEqual(self.host.snapshot()["latest_sequence"], "0")

        def call(name, arguments):
            result = self.host.request("surface_control_" + name, arguments)
            self.assertFalse(result["isError"], result)
            return result["structuredContent"]

        # The legacy client supplies the global sequence, never input_sequence or
        # writer identity. Responses may contain additive 1.3 fields.
        accepted = call("input", {"expected": expected, "expected_sequence": "0",
            "control_id": "a.encoder.1", "encoding": "scalar", "value": 127})
        self.assertEqual((accepted["sequence"], accepted["disposition"]), ("1", "accepted"))
        feedback = {"expected": expected, "control_id": "a.button.1", "kind": "indicator", "value": "blink"}
        if version == "1.1":
            feedback["expected_sequence"] = "1"
        shown = call("feedback", feedback)
        self.assertEqual(shown["sequence"], "2")
        held = call("input", {"expected": expected, "expected_sequence": "2", "control_id": "a.touch.1",
            "encoding": "boolean", "value": True, "hold_s": 5})
        renewed = call("renew", {"expected": expected, "control_id": "a.touch.1", "hold_s": 6})
        self.assertGreater(renewed["hold_deadline"], held["hold_deadline"])
        snapshot = self.host.snapshot()
        self.assertEqual(snapshot["latest_sequence"], "3")
        self.assertEqual(snapshot["inputs"]["a.encoder.1"], 127)
        self.assertTrue(snapshot["inputs"]["a.touch.1"])
        self.assertEqual(snapshot["feedback"]["a.button.1"]["indicator"], "blink")
        page = call("events", {"instance_id": "legacy.client", "epoch": expected["epoch"], "after_sequence": "0", "limit": 100})
        self.assertEqual([row["sequence"] for row in page["events"]], ["1", "2", "3"])
        self.assertEqual([row["kind"] for row in page["events"]], ["input", "feedback", "input"])
        if version == "1.2":
            self.assertEqual(page["holds"]["a.touch.1"], snapshot["holds"]["a.touch.1"])
        released = call("input", {"expected": expected, "expected_sequence": "3", "control_id": "a.touch.1",
            "encoding": "boolean", "value": False})
        self.assertEqual(released["sequence"], "4")
        self.assertNotIn("a.touch.1", self.host.snapshot().get("holds", {}))
        reset = call("reset", {"expected": expected, "expected_sequence": "4"})
        self.assertNotEqual(reset["expected"]["epoch"], expected["epoch"])
        self.assertEqual(self.host.snapshot()["latest_sequence"], "0")
        stale = self.host.request("surface_control_input", {"expected": expected, "expected_sequence": "0",
            "control_id": "a.encoder.1", "encoding": "scalar", "value": 0})
        self.assertEqual(stale["structuredContent"]["code"], "stale_epoch")

    def test_contract_1_1_wire_shapes_roundtrip_on_current_host(self):
        self.legacy_wire_roundtrip("1.1")

    def test_contract_1_2_wire_shapes_roundtrip_on_current_host(self):
        self.legacy_wire_roundtrip("1.2")
