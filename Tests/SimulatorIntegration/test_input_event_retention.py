"""Explicit retention through real headless processes; hardware uses only Debug fake MIDI."""
import sys
import tempfile
import unittest

from test_http_simulator import RunningSimulator, TOKEN, start_failure
from test_hardware_service import RunningHardware
from test_scoped_credentials import ScopedHost, credentials
from surface_control import Client, EventCursor, InputEventCursor, SurfaceError


class RetentionHardware(RunningHardware):
    def discover(self):
        return self.client.discover(versions=("1.5",), profiles=("xtouch.compact.standard.hardware",), profile_versions=("1.5",))


class InputRetentionHTTPTests(unittest.TestCase):
    def test_simulator_optin_lists_eighth_readonly_tool_and_survives_global_feedback_gap(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningSimulator(directory, "retention.test", extra=("--surface-input-event-capacity", "4", "--write-limit", "10000"))
            try:
                client = Client(host.ready["url"], TOKEN, "retention.test")
                discovery = client.discover(versions=("1.5",), profile_versions=("1.5",))
                self.assertEqual(discovery["profile"]["id"], "xtouch.compact.standard.simulation")
                self.assertIn("events.input_retention", discovery["profile"]["capabilities"])
                tools = host.rpc({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
                self.assertEqual(len(tools), 8)
                tool = next(tool for tool in tools if tool["name"] == "surface_control_input_events")
                self.assertTrue(tool["annotations"]["readOnlyHint"])
                cursor = InputEventCursor(client)
                cursor.bootstrap(client.snapshot())
                old = EventCursor(client)
                old.bootstrap(client.snapshot())
                accepted = client.input("a.encoder.1", "scalar", 47)
                # The existing global capacity remains1024. Feedback may evict its input,
                # but must never occupy the explicit independent capacity of4.
                for value in range(1025):
                    client.feedback("a.encoder.1", "value", value % 128)
                with self.assertRaises(SurfaceError) as caught:
                    old.poll()
                self.assertEqual(caught.exception.code, "event_gap")
                events = cursor.poll()
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0]["event"]["input_sequence"], "1")
                self.assertEqual(events[0]["event"]["value"], 47)
                self.assertEqual(events[0]["event"]["writer_id"], accepted["writer_id"])
                self.assertEqual(cursor.input_event_capacity, 4)
                self.assertEqual(cursor.poll(), [])
                self.assertEqual(client.snapshot()["latest_sequence"], "1026")
            finally:
                host.close()

    def test_simulator_reset_stales_old_cursor_and_preserves_explicit_capacity(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningSimulator(directory, "retention.reset", extra=("--surface-input-event-capacity", "2"))
            try:
                client = Client(host.ready["url"], TOKEN, "retention.reset")
                client.discover(versions=("1.5",))
                cursor = InputEventCursor(client)
                cursor.bootstrap(client.snapshot())
                client.input("a.encoder.1", "scalar", 20)
                client.reset()
                with self.assertRaises(SurfaceError) as caught:
                    cursor.poll()
                self.assertIn(caught.exception.code, ("stale_epoch", "context_changed"))
                client.discover(versions=("1.5",))
                page = client.call("surface_control_input_events", {"expected": client.expected, "after_input_sequence": "0", "limit": 10})
                self.assertEqual(page["events"], [])
                self.assertEqual(page["input_event_capacity"], 2)
                self.assertEqual(page["latest_input_sequence"], "0")
            finally:
                host.close()

    def test_default_has_exact_old_seven_and_strict_optin_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RunningSimulator(directory, "default.test")
            try:
                discovery = host.discover()
                self.assertEqual(discovery["contract_version"], "1.3")
                self.assertNotIn("events.input_retention", discovery["profile"]["capabilities"])
                tools = host.rpc({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
                self.assertEqual(len(tools), 7)
                response = host.request("surface_control_input_events", {})
                self.assertTrue(response["isError"])
                self.assertEqual(response["structuredContent"]["code"], "unsupported_tool")
            finally:
                host.close()
        for arguments in [("0",), ("65537",), ("not-an-integer",), ("2", "--surface-input-event-capacity", "2"), ()]:
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                status, _, _ = start_failure(directory, ["--surface-input-event-capacity", *arguments])
                self.assertNotEqual(status, 0)

    @unittest.skipUnless(sys.platform == "darwin", "XTouchSurfaceHardware target is macOS-only")
    def test_hardware_retained_input_uses_real_source_and_never_injects_or_moves(self):
        with tempfile.TemporaryDirectory() as directory:
            host = RetentionHardware(directory, extra=("--surface-input-event-capacity", "2"))
            try:
                cursor = InputEventCursor(host.client)
                cursor.bootstrap(host.client.snapshot())
                host.append({"bytes": [176, 28, 47]})
                events = cursor.poll()
                self.assertEqual(len(events), 1)
                event = events[0]["event"]
                self.assertEqual((event["control_id"], event["source"], event["origin"], event["value"]), ("b.fader.1", "hardware", "hardware", 47))
                rejected = host.raw("surface_control_input", {"expected": host.client.expected, "expected_sequence": host.client.latest_sequence, "control_id": "b.fader.1", "encoding": "scalar", "value": 99})
                self.assertEqual(rejected["structuredContent"]["code"], "permission_denied")
                self.assertEqual(host.output()["sent_count"], 0)
                host.append({"connected": False}, {"connected": True})
                with self.assertRaises(SurfaceError) as caught:
                    cursor.poll()
                self.assertEqual(caught.exception.code, "stale_epoch")
                host.client = Client(host.ready["url"], host.token, "hardware.test", accepted_sources=("hardware",))
                host.discover()
                page = host.client.call("surface_control_input_events", {"expected": host.client.expected, "after_input_sequence": "0", "limit": 10})
                self.assertEqual(page["events"], [])
                self.assertEqual(page["input_event_capacity"], 2)
                self.assertEqual(page["link"], {"state": "connected"})
                self.assertEqual(host.output()["sent_count"], 0)
            finally:
                host.close()

    def check_retention_roles(self, hardware=False):
        with tempfile.TemporaryDirectory() as directory:
            host = ScopedHost(directory, credentials(), hardware=hardware, extra=("--surface-input-event-capacity", "2", "--write-limit", "1"))
            try:
                expected = host.clients["owner"].expected
                for role, old_count in [("owner", 7), ("operator", 5), ("display", 4)]:
                    tools = host.rpc(role, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["tools"]
                    self.assertEqual(len(tools), old_count + 1)
                    self.assertEqual(tools[-1]["name"], "surface_control_input_events")
                    args = {"expected": expected, "after_input_sequence": "0", "limit": 2}
                    page = host.call(role, "surface_control_input_events", args)
                    self.assertFalse(page["isError"])
                    self.assertEqual(page["structuredContent"]["input_event_capacity"], 2)
                    for bad in [{**args, "extra": 1}, {**args, "after_input_sequence": "00"}, {**args, "limit": 0}, {**args, "expected": {**expected, "extra": "value"}}]:
                        result = host.call(role, "surface_control_input_events", bad)
                        self.assertEqual(result["structuredContent"]["code"], "invalid_argument")
                    stale = host.call(role, "surface_control_input_events", {**args, "expected": {**expected, "epoch": "old"}})
                    self.assertEqual(stale["structuredContent"]["code"], "stale_epoch")
                # Reading never consumes the aggregate write budget. Existing role protection
                # still precedes parsing for an unauthorized old mutation.
                denied = host.call("display", "surface_control_input", {})
                self.assertEqual(denied["structuredContent"]["code"], "permission_denied")
                layer = "b" if hardware else "a"
                written = host.clients["owner"].feedback(layer + ".encoder.1", "value", 5)
                self.assertEqual(written["kind"], "feedback")
                denied = host.call("owner", "surface_control_feedback", {"expected": expected, "control_id": layer + ".encoder.1", "kind": "value", "value": 6})
                self.assertEqual(denied["structuredContent"]["code"], "rate_limited")
            finally:
                host.close()

    def test_simulation_retention_is_visible_to_each_read_role_without_spending_writes(self):
        self.check_retention_roles()

    @unittest.skipUnless(sys.platform == "darwin", "XTouchSurfaceHardware target is macOS-only")
    def test_hardware_retention_is_visible_to_each_read_role_without_spending_writes(self):
        self.check_retention_roles(hardware=True)
