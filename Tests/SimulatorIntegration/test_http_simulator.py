"""Real subprocess + loopback tests; no MIDI, GUI, Pipe service, or user store."""
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import sys
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
# The single SDK source is the shared package, materialized at the locked revision (D19-6).
SHARED = ROOT / "build/dependencies/SurfacePlugins"
# The managed cache must stay clean (the dependency manager rejects any extra file there),
# so importing the SDK from it must not write __pycache__.
sys.dont_write_bytecode = True
sys.path.insert(0, str(SHARED / "clients/python"))
from surface_control import Client, CommandCursor, SurfaceError, mapping_revision  # noqa: E402

BINARY = Path(os.environ.get("XTOUCH_SIMULATOR_BINARY", ROOT / ".build/debug/XTouchSurfaceSimulator")).resolve()
# Same credential shape as the BCR Provider: 64 lowercase hexadecimal characters.
TOKEN = secrets.token_hex(32)


def copy_binary(directory):
    binary = Path(directory) / "XTouchSurfaceSimulator"
    if not binary.exists():
        shutil.copy2(BINARY, binary)
    return binary


def start_failure(directory, arguments, stdin=TOKEN + "\n"):
    """Run a startup expected to be refused; return its exit status and stderr."""
    completed = subprocess.run([str(copy_binary(directory)), *arguments], input=stdin, capture_output=True,
        text=True, cwd=directory, timeout=10)
    return completed.returncode, completed.stdout, completed.stderr


class RunningSimulator:
    def __init__(self, directory, instance=None, mutations=True, port=0, extra=(), token_file=None):
        self.directory = Path(directory)
        binary = copy_binary(self.directory)
        command = [str(binary), "--port", str(port), *extra]
        command += ["--token-file", str(token_file)] if token_file else ["--token-stdin"]
        if instance is not None:
            command += ["--surface-instance-id", instance]
        if mutations:
            command += ["--allow-surface-input", "--allow-surface-feedback", "--allow-surface-reset"]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, cwd=self.directory)
        if not token_file:
            self.process.stdin.write(TOKEN + "\n")
        self.process.stdin.close()
        self.ready = json.loads(self.process.stdout.readline())
        assert self.ready["status"] == "ready" and self.ready["source"] == "simulation"
        assert TOKEN not in json.dumps(self.ready)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()

    def request(self, name, args=None, token=TOKEN, origin=None):
        return self.rpc({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": args or {}}}, token=token, origin=origin)["result"]

    def rpc(self, envelope, token=TOKEN, origin=None, raw=None, protocol=None):
        data = raw if raw is not None else json.dumps(envelope).encode()
        headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
        if origin:
            headers["Origin"] = origin
        if protocol:
            headers["MCP-Protocol-Version"] = protocol
        request = urllib.request.Request(self.ready["url"], data, headers)
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)

    def discover(self):
        return self.request("surface_control_discover")["structuredContent"]

    def snapshot(self):
        return self.request("surface_control_snapshot", {"instance_id": self.ready["surface_control"]["expected"]["instance_id"]})["structuredContent"]

    def input(self, value=127, control="a.encoder.1", encoding="scalar"):
        discovery = self.discover()
        return {"expected": discovery["expected"], "expected_sequence": discovery["latest_sequence"],
            "control_id": control, "encoding": encoding, "value": value}


class SurfaceSimulatorHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.a = RunningSimulator(self.temporary.name, "car.a")

    def tearDown(self):
        self.a.close()
        self.temporary.cleanup()

    def test_discovery_input_feedback_and_stale_cas(self):
        discovery = self.a.discover()
        self.assertEqual(discovery["expected"], self.a.ready["surface_control"]["expected"])
        self.assertEqual(discovery["source"], "simulation")
        self.assertEqual(len(discovery["profile"]["controls"]), 184)
        self.assertEqual(discovery["profile"]["version"], "1.2")
        request = self.a.input()
        accepted = self.a.request("surface_control_input", request)
        self.assertFalse(accepted["isError"])
        event = accepted["structuredContent"]
        self.assertEqual((event["disposition"], event["source"], event["origin"]), ("accepted", "simulation", "remote"))
        repeated = self.a.request("surface_control_input", request)
        self.assertEqual(repeated["structuredContent"]["code"], "stale_sequence")
        shown = self.a.request("surface_control_feedback", {"expected": discovery["expected"], "expected_sequence": event["sequence"],
            "control_id": "a.button.1", "kind": "indicator", "value": "blink"})["structuredContent"]
        snapshot = self.a.snapshot()
        self.assertEqual(snapshot["inputs"]["a.encoder.1"], 127)
        self.assertEqual(snapshot["inputs"]["a.button.1"], False)
        self.assertEqual(snapshot["feedback"]["a.button.1"]["indicator"], "blink")
        page = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": discovery["expected"]["epoch"],
            "after_sequence": "0", "limit": 100})["structuredContent"]
        self.assertEqual([event["kind"] for event in page["events"]], ["input", "feedback"])
        self.assertGreaterEqual(page["server_time"], shown["time"])

    def test_slow_drip_has_one_total_deadline_and_listener_recovers(self):
        stopped = threading.Event()
        with socket.create_connection(("127.0.0.1", self.a.ready["port"]), timeout=5) as connection:
            connection.sendall(b"P")
            def drip():
                while not stopped.wait(0.2):
                    try:
                        connection.sendall(b"x")
                    except OSError:
                        break
            writer = threading.Thread(target=drip, daemon=True)
            started = time.monotonic()
            writer.start()
            try:
                reply = connection.recv(4096)
                self.assertLess(time.monotonic() - started, 4.2)
                self.assertTrue(reply.startswith(b"HTTP/1.1 400"))
            finally:
                stopped.set()
                writer.join(timeout=1)
        started = time.monotonic()
        self.assertEqual(self.a.discover()["source"], "simulation")
        self.assertLess(time.monotonic() - started, 1)

    def test_denials_and_bad_encoding_are_side_effect_free(self):
        for token, origin, status in [("wrong-token", None, 401), (TOKEN, "https://untrusted.invalid", 403)]:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.a.request("surface_control_discover", token=token, origin=origin)
            self.assertEqual(caught.exception.code, status)
            caught.exception.close()
        request = self.a.input()
        request["encoding"] = "signedDelta"
        result = self.a.request("surface_control_input", request)
        self.assertEqual(result["structuredContent"]["code"], "unsupported_encoding")
        self.assertEqual(self.a.snapshot()["latest_sequence"], "0")
        request = self.a.input()
        request["source"] = "hardware"
        result = self.a.request("surface_control_input", request)
        self.assertEqual(result["structuredContent"]["code"], "invalid_argument")
        self.assertEqual(self.a.snapshot()["latest_sequence"], "0")

    def test_lost_response_is_accepted_once_and_old_request_cannot_replay(self):
        args = self.a.input()
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "surface_control_input", "arguments": args}}).encode()
        header = ("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer " + TOKEN +
            "\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)) + "\r\n\r\n").encode()
        with socket.create_connection(("127.0.0.1", self.a.ready["port"]), timeout=3) as connection:
            connection.sendall(header + body)
            # Intentionally discard the response: the caller has an unknown outcome.
        deadline = time.monotonic() + 3
        while self.a.snapshot()["latest_sequence"] != "1" and time.monotonic() < deadline:
            time.sleep(0.01)
        result = self.a.request("surface_control_input", args)
        self.assertEqual(result["structuredContent"]["code"], "stale_sequence")
        self.assertEqual(self.a.snapshot()["latest_sequence"], "1")

    def test_same_public_sdk_consumes_both_supported_protocols(self):
        for protocol in ("2025-11-25", "2026-07-28"):
            client = Client(self.a.ready["url"], TOKEN, "car.a", protocol=protocol)
            cursor = CommandCursor(client, {name: "simulation." + name for name in ("arm", "start", "pause", "cancel")})
            self.assertEqual(cursor.bootstrap(), {"arm": 0, "start": 0, "pause": 0, "cancel": 0})
            client.input("a.encoder.1", "scalar", 127)
            samples = cursor.poll()
            self.assertEqual(len(samples), 1)
            self.assertEqual(samples[0]["values"]["arm"], 1)
            cursor.verify(samples[0])
            client.feedback("a.button.1", "indicator", "on")
            self.assertEqual(cursor.poll(), [])
            client.input("a.encoder.1", "scalar", 127)
            self.assertEqual(cursor.poll(), [])
            client.reset()
            with self.assertRaises(SurfaceError):
                cursor.poll()
            self.assertTrue(cursor.invalidated)

    def test_shared_sdk_pins_contract_1_2_and_the_derived_mapping_revision(self):
        client = Client(self.a.ready["url"], TOKEN, "car.a")
        discovery = client.discover(profiles=("xtouch.compact.standard.simulation",), profile_versions=("1.2",))
        self.assertEqual(discovery["contract_version"], "1.2")
        self.assertEqual(discovery["expected"]["mapping_revision"], mapping_revision(discovery["profile"]))
        self.assertIn("input.hold", discovery["profile"]["capabilities"])
        self.assertIn("x.xtouch.touch_protection", discovery["profile"]["capabilities"])
        # A layer key keeps identity, so the pinned client remains valid without rediscovery.
        client.input("global.layer.b", "boolean", True)
        self.assertEqual(client.discover()["expected"], discovery["expected"])
        client.reset()
        self.assertEqual(client.expected["mapping_revision"], discovery["expected"]["mapping_revision"])
        self.assertNotEqual(client.expected["epoch"], discovery["expected"]["epoch"])

    def test_concurrent_input_and_unsequenced_feedback_refresh_after_stale_sequence(self):
        operator = Client(self.a.ready["url"], TOKEN, "car.a")
        discovery = operator.discover()
        expected = discovery["expected"]
        self.assertIn("feedback.unsequenced", discovery["profile"]["capabilities"])
        self.assertIn("controls.input_declared", discovery["profile"]["capabilities"])
        self.assertTrue(all(row["accepts_input"] is True for row in discovery["profile"]["controls"]))
        failures, feedback_events, input_events = [], [], []

        def display(value):
            # The real HTTP request deliberately omits expected_sequence.
            result = self.a.request("surface_control_feedback", {"expected": expected,
                "control_id": "a.encoder.10", "kind": "value", "value": value})
            self.assertFalse(result["isError"], result)
            feedback_events.append(result["structuredContent"])

        # Force one collision: feedback occupies the operator's old sequence, input is not run.
        display(0)
        with self.assertRaises(SurfaceError) as conflict:
            operator.input("a.encoder.9", "scalar", 1)
        self.assertEqual(conflict.exception.code, "stale_sequence")
        self.assertEqual(self.a.snapshot()["inputs"]["a.encoder.9"], 0)
        operator.refresh_sequence()
        input_events.append(operator.input("a.encoder.9", "scalar", 1))
        barrier = threading.Barrier(2)
        stale = [1]

        def write_inputs():
            try:
                barrier.wait(timeout=5)
                for value in range(2, 14):
                    for attempt in range(30):
                        try:
                            input_events.append(operator.input("a.encoder.9", "scalar", value))
                            break
                        except SurfaceError as error:
                            if error.code != "stale_sequence":
                                raise
                            stale[0] += 1
                            operator.refresh_sequence()
                    else:
                        self.fail("input did not converge after explicit sequence refresh")
            except BaseException as error:
                failures.append(error)

        def write_feedback():
            try:
                barrier.wait(timeout=5)
                for value in range(1, 13):
                    display(value)
            except BaseException as error:
                failures.append(error)

        workers = [threading.Thread(target=write_inputs), threading.Thread(target=write_feedback)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive())
        self.assertEqual(failures, [])
        self.assertGreaterEqual(stale[0], 1)
        self.assertEqual(len(feedback_events), 13)
        self.assertTrue(all(event["disposition"] == "accepted" for event in feedback_events))
        self.assertEqual(len(input_events), 13)
        self.assertTrue(all(event["disposition"] == "accepted" for event in input_events))
        snapshot = self.a.snapshot()
        self.assertEqual(snapshot["latest_sequence"], "26")
        self.assertEqual(snapshot["inputs"]["a.encoder.9"], 13)
        self.assertEqual(snapshot["feedback"]["a.encoder.10"]["value"], 12)
        page = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": expected["epoch"],
            "after_sequence": "0", "limit": 100})["structuredContent"]
        self.assertEqual(len(page["events"]), 26)

    def test_event_pages_report_current_holds_after_acquire_renew_and_expiry(self):
        client = Client(self.a.ready["url"], TOKEN, "car.a")
        discovery = client.discover()
        def events():
            return self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": discovery["expected"]["epoch"],
                "after_sequence": "0", "limit": 100})["structuredContent"]
        self.assertNotIn("holds", events())
        held = client.input("a.touch.1", "boolean", True, hold_s=0.3)
        self.assertEqual(events()["holds"], {"a.touch.1": held["hold_deadline"]})
        renewed = client.renew("a.touch.1", 0.3)
        self.assertEqual(events()["holds"], {"a.touch.1": renewed["hold_deadline"]})
        time.sleep(0.4)
        page = events()
        self.assertNotIn("holds", page)
        self.assertEqual(page["events"][-1]["reason"], "hold_expired")

    def test_describe_matches_live_discovery_and_the_sdk_mapping_revision(self):
        # The delivery manifest takes profile identity and mapping_revision from --describe.
        described = json.loads(subprocess.run([str(copy_binary(self.temporary.name)), "--describe"],
            capture_output=True, text=True, check=True, timeout=10).stdout)["discovery"]
        live = self.a.discover()
        self.assertEqual(described["profile"], live["profile"])
        self.assertEqual(described["contract_version"], live["contract_version"])
        self.assertEqual(described["expected"]["mapping_revision"], live["expected"]["mapping_revision"])
        self.assertEqual(described["expected"]["mapping_revision"], mapping_revision(live["profile"]))

    def test_renew_is_silent_permissioned_and_budgeted(self):
        client = Client(self.a.ready["url"], TOKEN, "car.a")
        client.discover()
        held = client.input("a.touch.1", "boolean", True, hold_s=5)
        self.assertEqual(held["sequence"], "1")
        self.assertAlmostEqual(held["hold_deadline"] - held["time"], 5, places=6)
        renewed = client.renew("a.touch.1", 5)
        self.assertGreater(renewed["hold_deadline"], held["hold_deadline"])
        snapshot = client.snapshot()
        self.assertEqual(snapshot["latest_sequence"], "1")
        self.assertEqual(snapshot["holds"], {"a.touch.1": renewed["hold_deadline"]})
        page = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": client.expected["epoch"],
            "after_sequence": "0", "limit": 100})["structuredContent"]
        self.assertEqual(len(page["events"]), 1)
        for control, code in (("a.button.1", "unsupported_hold"), ("a.touch.2", "hold_expired")):
            reply = self.a.request("surface_control_renew", {"expected": client.expected, "control_id": control, "hold_s": 1})
            self.assertEqual(reply["structuredContent"]["code"], code)
        with tempfile.TemporaryDirectory() as other:
            readonly = RunningSimulator(other, "car.ro", mutations=False)
            try:
                expected = readonly.discover()["expected"]
                reply = readonly.request("surface_control_renew", {"expected": expected, "control_id": "a.touch.1", "hold_s": 1})
                self.assertEqual(reply["structuredContent"]["code"], "permission_denied")
            finally:
                readonly.close()
        # Renewals are writes: the shared 60/s budget eventually rejects them with rate_limited,
        # which leaves the lease deadline unchanged.
        last = client.snapshot()["holds"]["a.touch.1"]
        limited = None
        for _ in range(130):
            reply = self.a.request("surface_control_renew", {"expected": client.expected, "control_id": "a.touch.1",
                "hold_s": 5})["structuredContent"]
            if reply.get("code") == "rate_limited":
                limited = reply
                break
            self.assertNotIn("code", reply)
            last = reply["hold_deadline"]
        self.assertIsNotNone(limited)
        snapshot = client.snapshot()
        self.assertEqual((snapshot["latest_sequence"], snapshot["holds"]["a.touch.1"]), ("1", last))

    def test_lease_expires_on_the_process_clock_without_any_request(self):
        client = Client(self.a.ready["url"], TOKEN, "car.a")
        client.discover()
        held = client.input("a.touch.3", "boolean", True, hold_s=0.3)
        time.sleep(1.0)
        # The idle accept loop processed the expiry before this read; the read never sees it pending.
        snapshot = client.snapshot()
        self.assertEqual(snapshot["inputs"]["a.touch.3"], False)
        self.assertNotIn("holds", snapshot)
        self.assertEqual(snapshot["latest_sequence"], "2")
        page = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": client.expected["epoch"],
            "after_sequence": "1", "limit": 100})["structuredContent"]
        expired = page["events"][0]
        self.assertEqual((expired["kind"], expired["disposition"], expired["reason"], expired["origin"], expired["value"]),
            ("input", "accepted", "hold_expired", "remote", False))
        # Processed on schedule, not at the next request: within a small margin of the deadline.
        self.assertGreaterEqual(expired["time"], held["hold_deadline"])
        self.assertLess(expired["time"] - held["hold_deadline"], 0.3)
        reply = self.a.request("surface_control_renew", {"expected": client.expected, "control_id": "a.touch.3", "hold_s": 1})
        self.assertEqual(reply["structuredContent"]["code"], "hold_expired")

    def expiry_lateness_under_slow_drip(self, control, hold_s=0.3):
        """Seconds between a lease deadline and its hold_expired event while a drip holds the reader."""
        client = Client(self.a.ready["url"], TOKEN, "car.a")
        client.discover()
        stopped = threading.Event()
        # The lease is acquired on a normal request before the drip takes the reader.
        held = client.input(control, "boolean", True, hold_s=hold_s)
        with socket.create_connection(("127.0.0.1", self.a.ready["port"]), timeout=5) as busy:
            # An unauthenticated peer that never completes its request: it owns the serial
            # reader for the whole three-second read budget.
            def drip():
                while not stopped.wait(0.05):
                    try:
                        busy.sendall(b"x")
                    except OSError:
                        break

            busy.sendall(b"P")
            writer = threading.Thread(target=drip, daemon=True)
            writer.start()
            try:
                started = time.monotonic()
                reply = busy.recv(4096)  # The drip is cut off by its own total budget.
                occupied = time.monotonic() - started
            finally:
                stopped.set()
                writer.join(timeout=1)
        self.assertTrue(reply.startswith(b"HTTP/1.1 400"))
        self.assertGreater(occupied, hold_s + 1.5)  # The reader really was busy across the deadline.
        self.assertLess(occupied, 4.2)
        page = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": client.expected["epoch"],
            "after_sequence": held["sequence"], "limit": 100})["structuredContent"]
        expired = page["events"][0]
        self.assertEqual((expired["control_id"], expired["reason"], expired["disposition"], expired["value"]),
            (control, "hold_expired", "accepted", False))
        return expired["time"] - held["hold_deadline"]

    def test_lease_expires_within_bound_while_a_slow_drip_holds_the_reader(self):
        lateness = [self.expiry_lateness_under_slow_drip("a.touch.%d" % index) for index in (5, 6, 7)]
        print("\nhold expiry lateness under slow drip (s):", ", ".join("%.4f" % value for value in lateness), file=sys.stderr)
        # Measured values are kept as evidence next to the scenario reports.
        report = ROOT / "build/surface-expiry-latency.json"
        report.parent.mkdir(exist_ok=True)
        report.write_text(json.dumps({"condition": "slow drip holds the reader across the deadline", "hold_s": 0.3,
            "hard_limit_s": 0.5, "lateness_s": lateness, "binary": str(BINARY)}) + "\n")
        for value in lateness:
            self.assertGreaterEqual(value, 0)
            # Documented hard bound: the event is never later than deadline + 0.5 s, although the
            # reader stays occupied for about three seconds. Expected lateness is a few milliseconds.
            self.assertLess(value, 0.5)

    def test_lease_due_before_a_request_is_processed_first_never_pending(self):
        client = Client(self.a.ready["url"], TOKEN, "car.a")
        client.discover()
        client.input("a.touch.4", "boolean", True, hold_s=0.2)
        # Hold the serial listener with a slow request so the idle timer cannot fire first.
        with socket.create_connection(("127.0.0.1", self.a.ready["port"]), timeout=5) as connection:
            connection.sendall(b"POST /mcp HTTP/1.1\r\n")
            time.sleep(0.5)
        snapshot = client.snapshot()
        self.assertEqual((snapshot["inputs"]["a.touch.4"], snapshot["latest_sequence"]), (False, "2"))

    def test_both_protocols_carry_input_feedback_reset_semantics(self):
        for protocol in ("2025-11-25", "2026-07-28"):
            initialized = self.a.rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": protocol, "capabilities": {}}}, protocol=protocol)
            self.assertEqual(initialized["result"]["protocolVersion"], protocol)
            discovery = self.a.discover()
            cursor = discovery["latest_sequence"]
            accepted = self.a.request("surface_control_input", self.a.input(127))["structuredContent"]
            self.assertEqual((accepted["disposition"], accepted["mapped_value"]), ("accepted", 127))
            feedback = self.a.request("surface_control_feedback", {"expected": discovery["expected"],
                "expected_sequence": accepted["sequence"], "control_id": "a.button.1", "kind": "indicator",
                "value": "on"})["structuredContent"]
            self.assertEqual(feedback["kind"], "feedback")
            repeated = self.a.request("surface_control_input", self.a.input(127))["structuredContent"]
            self.assertEqual((repeated["disposition"], repeated["reason"]), ("ignored", "no_change"))
            page = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": discovery["expected"]["epoch"],
                "after_sequence": cursor, "limit": 100})["structuredContent"]
            self.assertEqual([(e["kind"], e["disposition"]) for e in page["events"]],
                [("input", "accepted"), ("feedback", "accepted"), ("input", "ignored")])
            current = self.a.discover()
            reset = self.a.request("surface_control_reset", {"expected": current["expected"],
                "expected_sequence": current["latest_sequence"]})["structuredContent"]
            self.assertNotEqual(reset["expected"]["epoch"], discovery["expected"]["epoch"])
            stale = self.a.request("surface_control_events", {"instance_id": "car.a", "epoch": discovery["expected"]["epoch"],
                "after_sequence": "0", "limit": 100})["structuredContent"]
            self.assertEqual(stale["code"], "stale_epoch")

    def test_public_layer_keys_reach_inactive_layer_without_new_epoch(self):
        before = self.a.discover()
        ignored = self.a.request("surface_control_input", self.a.input(100, "b.fader.1"))["structuredContent"]
        self.assertEqual(ignored["reason"], "inactive_layer")
        press = self.a.request("surface_control_input", self.a.input(True, "global.layer.b", "boolean"))["structuredContent"]
        self.assertEqual((press["disposition"], press["mapped_value"]), ("accepted", "b"))
        accepted = self.a.request("surface_control_input", self.a.input(100, "b.fader.1"))["structuredContent"]
        self.assertEqual(accepted["disposition"], "accepted")
        after = self.a.discover()
        self.assertEqual(after["expected"], before["expected"])
        self.assertEqual(after["latest_sequence"], "3")
        self.assertEqual(self.a.snapshot()["inputs"]["b.fader.1"], 100)
        pedal = self.a.request("surface_control_input", self.a.input(64, "b.expression.1"))["structuredContent"]
        self.assertEqual(pedal["disposition"], "accepted")
        self.assertEqual(self.a.request("surface_control_input", self.a.input(5, "a.expression.1"))["structuredContent"]["reason"],
            "inactive_layer")

    def test_json_rpc_error_codes(self):
        cases = [
            (b"{not json", -32700),
            (json.dumps([1, 2]).encode(), -32600),
            (json.dumps({"jsonrpc": "1.0", "id": 1, "method": "ping"}).encode(), -32600),
            (json.dumps({"jsonrpc": "2.0", "id": {"x": 1}, "method": "ping"}).encode(), -32600),
            (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping", "params": 3}).encode(), -32600),
            (json.dumps({"jsonrpc": "2.0", "id": 7, "method": "resources/list"}).encode(), -32601),
            (json.dumps({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"arguments": {}}}).encode(), -32602),
        ]
        for raw, code in cases:
            with self.subTest(code=code, raw=raw):
                reply = self.a.rpc(None, raw=raw)
                self.assertEqual(reply["error"]["code"], code)
                self.assertNotIn("result", reply)
        self.assertEqual(self.a.rpc({"jsonrpc": "2.0", "id": 7, "method": "resources/list"})["id"], 7)
        # A tool-level failure is still a result with the shared stable code, not a JSON-RPC error.
        unknown = self.a.request("surface_control_missing")
        self.assertTrue(unknown["isError"])
        self.assertEqual(self.a.snapshot()["latest_sequence"], "0")

    def test_failed_mutations_do_not_consume_write_budget(self):
        # Budget window: 60 committed writes per second. Failed validation never consumes it,
        # so 61 rejected writes followed by 60 valid ones all fit one window; the 61st valid
        # write is the first rate-limited one and leaves the journal unchanged.
        expected = self.a.discover()["expected"]
        def write(sequence, value, encoding="scalar"):
            return self.a.request("surface_control_input", {"expected": expected, "expected_sequence": str(sequence),
                "control_id": "a.encoder.1", "encoding": encoding, "value": value})["structuredContent"]
        for attempt in range(3):
            started = time.monotonic()
            base = int(self.a.snapshot()["latest_sequence"])
            for index in range(61):
                failure = write(base + 1, 1) if index % 2 else write(base, 1, "signedDelta")
                self.assertIn(failure["code"], {"stale_sequence", "unsupported_encoding"})
            accepted = []
            for index in range(61):
                reply = write(base + len(accepted), (len(accepted) + 1) % 2 * 127)
                if reply.get("code") == "rate_limited":
                    break
                self.assertEqual(reply["disposition"], "accepted")
                accepted.append(reply)
            if time.monotonic() - started < 0.9:
                break
            time.sleep(1.1)  # A slow host straddled the window; retry in a fresh one.
        else:
            self.skipTest("loopback too slow to fit one budget window")
        self.assertEqual(len(accepted), 60)
        self.assertEqual(self.a.snapshot()["latest_sequence"], str(base + 60))

    def test_default_instance_changes_when_same_port_restarts(self):
        self.a.close()
        self.a = RunningSimulator(self.temporary.name)
        old = self.a.input()
        old_port = self.a.ready["port"]
        self.a.close()
        self.a = RunningSimulator(self.temporary.name, port=old_port)
        self.assertEqual(self.a.ready["port"], old_port)
        current = self.a.discover()["expected"]
        self.assertNotEqual(old["expected"]["instance_id"], current["instance_id"])
        self.assertNotEqual(old["expected"]["epoch"], current["epoch"])
        rejected = self.a.request("surface_control_input", old)
        self.assertEqual(rejected["structuredContent"]["code"], "instance_mismatch")
        self.assertEqual(self.a.snapshot()["latest_sequence"], "0")

    def test_restart_reset_and_other_instance_isolation(self):
        with tempfile.TemporaryDirectory() as other_directory:
            b = RunningSimulator(other_directory, "car.b", mutations=False)
            try:
                before_b = b.snapshot()
                denied = b.request("surface_control_input", b.input())
                self.assertEqual(denied["structuredContent"]["code"], "permission_denied")
                old = self.a.input()
                self.a.request("surface_control_input", old)
                discovery = self.a.discover()
                reset = self.a.request("surface_control_reset", {"expected": discovery["expected"],
                    "expected_sequence": discovery["latest_sequence"]})["structuredContent"]
                self.assertNotEqual(reset["expected"]["epoch"], old["expected"]["epoch"])
                self.assertEqual(self.a.snapshot()["inputs"]["a.encoder.1"], 0)
                self.assertEqual(self.a.request("surface_control_input", old)["structuredContent"]["code"], "stale_epoch")
                self.a.close()
                self.a = RunningSimulator(self.temporary.name, "car.a")
                self.assertNotEqual(self.a.discover()["expected"]["epoch"], reset["expected"]["epoch"])
                after_b = b.snapshot()
                for key in ("discovery", "latest_sequence", "inputs", "feedback"):
                    self.assertEqual(after_b[key], before_b[key])
            finally:
                b.close()



class SurfaceSimulatorStartupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def private_token_file(self, name="token", mode=0o600, content=TOKEN + "\n"):
        path = self.directory / name
        path.write_text(content)
        path.chmod(mode)
        return path

    def test_instance_identity_is_bounded_visible_ascii(self):
        for instance in ("", "x" * 129, "car a", "car\u00e9", "car\tb"):
            with self.subTest(instance=instance):
                status, stdout, _ = start_failure(self.directory, ["--token-stdin", "--surface-instance-id", instance])
                self.assertNotEqual(status, 0)
                self.assertEqual(stdout, "")
        running = RunningSimulator(self.directory, "!" + "~" * 127, mutations=False)
        try:
            self.assertEqual(running.discover()["expected"]["instance_id"], "!" + "~" * 127)
        finally:
            running.close()

    def test_token_stdin_must_be_a_dedicated_pipe(self):
        # Same rule as the BCR Provider: a redirected file would bypass the --token-file checks.
        redirected = self.private_token_file("redirected", 0o644)
        with open(redirected, encoding="utf-8") as stream:
            completed = subprocess.run([str(copy_binary(self.directory)), "--token-stdin"], stdin=stream,
                capture_output=True, text=True, cwd=self.directory, timeout=10)
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, "")

    def test_token_must_be_64_lowercase_hex(self):
        for token in ("isolated-simulation-test-token", TOKEN.upper(), TOKEN[:-1], TOKEN + "0", "g" * 64, ""):
            with self.subTest(token=token):
                status, stdout, _ = start_failure(self.directory, ["--token-stdin"], stdin=token + "\n")
                self.assertNotEqual(status, 0)
                self.assertEqual(stdout, "")
        status, _, _ = start_failure(self.directory, [])
        self.assertNotEqual(status, 0)
        both = self.private_token_file()
        status, _, _ = start_failure(self.directory, ["--token-stdin", "--token-file", str(both)])
        self.assertNotEqual(status, 0)

    def test_token_file_must_be_private_owned_regular_file(self):
        good = self.private_token_file()
        running = RunningSimulator(self.directory, "car.file", mutations=False, token_file=good)
        try:
            self.assertEqual(running.discover()["source"], "simulation")
        finally:
            running.close()
        for mode in (0o640, 0o604, 0o644, 0o610, 0o601):
            with self.subTest(mode=oct(mode)):
                path = self.private_token_file("token-%o" % mode, mode)
                status, stdout, _ = start_failure(self.directory, ["--token-file", str(path)])
                self.assertNotEqual(status, 0)
                self.assertEqual(stdout, "")
        link = self.directory / "token-link"
        link.symlink_to(good)
        status, _, _ = start_failure(self.directory, ["--token-file", str(link)])
        self.assertNotEqual(status, 0)
        status, _, _ = start_failure(self.directory, ["--token-file", str(self.directory)])
        self.assertNotEqual(status, 0)
        fifo = self.directory / "token-fifo"
        os.mkfifo(fifo, 0o600)
        status, _, _ = start_failure(self.directory, ["--token-file", str(fifo)])
        self.assertNotEqual(status, 0)
        weak = self.private_token_file("weak", 0o600, "isolated-simulation-test-token\n")
        status, _, _ = start_failure(self.directory, ["--token-file", str(weak)])
        self.assertNotEqual(status, 0)

    def test_ready_file_is_exclusive_and_removed_on_termination(self):
        for stop in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=stop):
                ready = self.directory / ("ready-%d.json" % stop)
                running = RunningSimulator(self.directory, "car.ready", mutations=False, extra=("--ready-file", str(ready)))
                try:
                    self.assertEqual(json.loads(ready.read_text()), running.ready)
                    self.assertNotIn(TOKEN, ready.read_text())
                    running.process.send_signal(stop)
                    running.process.wait(timeout=5)
                    self.assertFalse(ready.exists())
                finally:
                    running.close()
        occupied = self.directory / "occupied.json"
        occupied.write_text("{}")
        status, stdout, _ = start_failure(self.directory, ["--token-stdin", "--ready-file", str(occupied)])
        self.assertNotEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(occupied.read_text(), "{}")

    def test_minimal_consumer_example_uses_private_token_file_and_ready_file(self):
        token = self.private_token_file()
        ready = self.directory / "ready.json"
        running = RunningSimulator(self.directory, "car.example", token_file=token, extra=("--ready-file", str(ready)))
        try:
            example = ROOT / "examples/surface_simulator/minimal_consumer.py"
            completed = subprocess.run([sys.executable, "-I", str(example), "--ready-file", str(ready),
                "--token-file", str(token), "--exercise"], capture_output=True, text=True, timeout=20, check=True)
            result = json.loads(completed.stdout)
            self.assertEqual(result["source"], "simulation")
            self.assertEqual((result["input"]["disposition"], result["input"]["control_id"]), ("accepted", "a.encoder.1"))
            self.assertEqual(result["feedback"]["control_id"], "a.button.2")
            self.assertEqual(running.snapshot()["latest_sequence"], "2")
        finally:
            running.close()

    def test_termination_never_removes_a_ready_file_it_did_not_create(self):
        ready = self.directory / "ready.json"
        running = RunningSimulator(self.directory, "car.ready", mutations=False, extra=("--ready-file", str(ready)))
        try:
            # Unlink plus immediate creation deliberately exercises inode reuse on Linux.
            # The simulator must retain an open descriptor to its original inode.
            original = ready.stat()
            ready.unlink()
            ready.write_text("other process")
            replacement = ready.stat()
            self.assertNotEqual((original.st_dev, original.st_ino), (replacement.st_dev, replacement.st_ino))
            running.process.terminate()
            running.process.wait(timeout=5)
            self.assertEqual(ready.read_text(), "other process")
        finally:
            running.close()


class SimulationConfigurationHTTPTests(unittest.TestCase):
    def test_example_describe_and_momentary_expiry(self):
        example = ROOT / "examples/surface_simulator/chassis.json"
        with tempfile.TemporaryDirectory() as directory:
            described = subprocess.run([str(copy_binary(directory)), "--simulation-configuration", str(example), "--describe"],
                capture_output=True, text=True, cwd=directory, check=True)
            discovery = json.loads(described.stdout)["discovery"]
            mappings = {row["mapping"]["id"]: row for row in discovery["profile"]["controls"] if row.get("mapping")}
            self.assertEqual(set(mappings), {"simulation." + role for role in
                ("enable", "linear", "steer", "stop", "speed_feedback", "steer_feedback", "stopped_feedback")})
            self.assertTrue(all(row["accepts_input"] for row in mappings.values()))
            self.assertEqual(mappings["simulation.enable"]["hold"], {"rest_value": False, "max_hold_s": 10})
            simulator = RunningSimulator(directory, "configured", extra=("--simulation-configuration", str(example)))
            try:
                request = simulator.input(True, "a.touch.1", "boolean")
                request["hold_s"] = 0.05
                pressed = simulator.request("surface_control_input", request)["structuredContent"]
                self.assertEqual(pressed["mapped_value"], 1)
                deadline = time.monotonic() + 1
                while simulator.snapshot().get("holds") and time.monotonic() < deadline:
                    time.sleep(0.01)
                page = simulator.request("surface_control_events", {"instance_id": "configured",
                    "epoch": discovery["expected"]["epoch"], "after_sequence": "0", "limit": 100})
                # Describe has a discovery-only epoch; the running process must reject that pin.
                self.assertEqual(page["structuredContent"]["code"], "stale_epoch")
                running = simulator.discover()
                page = simulator.request("surface_control_events", {"instance_id": "configured",
                    "epoch": running["expected"]["epoch"], "after_sequence": "0", "limit": 100})["structuredContent"]
                self.assertEqual([(event["kind"], event["mapped_value"]) for event in page["events"]],
                    [("input", 1), ("input", 0)])
                self.assertEqual(page["events"][-1]["reason"], "hold_expired")
            finally:
                simulator.close()

    def test_custom_write_limit_is_shared_atomic_and_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            simulator = RunningSimulator(directory, "budget", extra=("--write-limit", "2"))
            try:
                request = simulator.input(True, "a.touch.1", "boolean")
                request["hold_s"] = 5
                acquired = simulator.request("surface_control_input", request)["structuredContent"]
                expected = simulator.discover()["expected"]
                shown = simulator.request("surface_control_feedback", {"expected": expected,
                    "control_id": "a.encoder.10", "kind": "value", "value": 10})["structuredContent"]
                self.assertEqual(shown["sequence"], "2")
                before = simulator.snapshot()
                operations = [("surface_control_input", simulator.input(127)),
                    ("surface_control_feedback", {"expected": expected, "control_id": "a.encoder.10", "kind": "value", "value": 99}),
                    ("surface_control_renew", {"expected": expected, "control_id": "a.touch.1", "hold_s": 5}),
                    ("surface_control_reset", {"expected": expected, "expected_sequence": "2"})]
                for name, arguments in operations:
                    self.assertEqual(simulator.request(name, arguments)["structuredContent"]["code"], "rate_limited")
                    snapshot = simulator.snapshot()
                    for key in ("expected", "latest_sequence", "inputs", "feedback", "holds"):
                        self.assertEqual(snapshot.get(key), before.get(key), key)
                time.sleep(1.05)
                renewed = simulator.request("surface_control_renew", {"expected": expected,
                    "control_id": "a.touch.1", "hold_s": 5})
                self.assertFalse(renewed["isError"], renewed)
                self.assertGreater(renewed["structuredContent"]["hold_deadline"], acquired["hold_deadline"])
                self.assertFalse(simulator.request("surface_control_input", simulator.input(127))["isError"])
            finally:
                simulator.close()
            for value in ("0", "-1", "10001", "2.5", "bad"):
                code, stdout, stderr = start_failure(directory, ["--write-limit", value, "--describe"])
                self.assertNotEqual(code, 0)
                self.assertEqual(stdout, "")
                self.assertIn("invalidArguments", stderr)

    def test_strict_configuration_rejects_invalid_fields_bindings_and_permissions(self):
        original = json.loads((ROOT / "examples/surface_simulator/chassis.json").read_text())
        variants = []
        def variant(change):
            value = json.loads(json.dumps(original))
            change(value)
            variants.append(value)
        variant(lambda value: value.update(unknown=True))
        variant(lambda value: value["parameters"][0].update(unknown=True))
        variant(lambda value: value["assignments"][0].update(unknown=True))
        variant(lambda value: value["assignments"].append(value["assignments"][0]))
        variant(lambda value: value["assignments"][0].update(control={"faderTouch": {"_0": 10}}))
        variant(lambda value: value["assignments"][0].update(action={"set": {"_0": "simulation.enable", "_1": 1}}))
        variant(lambda value: value["parameters"][0].update(agentWritable=False))
        variant(lambda value: value["parameters"][0].update(externallyProtected=True))
        variant(lambda value: value.update(version=2) or value["parameters"][0].update(externallyProtected=True))
        variant(lambda value: value["assignments"][0].update(control={"faderTouch": {"_0": 1, "unknown": 0}}))
        with tempfile.TemporaryDirectory() as directory:
            for value in variants:
                path = Path(directory) / "invalid.json"
                path.write_text(json.dumps(value))
                with self.subTest(configuration=value):
                    code, stdout, stderr = start_failure(directory, ["--simulation-configuration", str(path), "--describe"])
                    self.assertNotEqual(code, 0)
                    self.assertEqual(stdout, "")
                    self.assertIn("failed", stderr)
            # v2 unprotected is explicitly supported, while v1 with this new field is refused.
            valid = json.loads(json.dumps(original))
            valid["version"] = 2
            valid["parameters"][0]["externallyProtected"] = False
            path.write_text(json.dumps(valid))
            described = subprocess.run([str(copy_binary(directory)), "--simulation-configuration", str(path), "--describe"],
                capture_output=True, text=True, cwd=directory)
            self.assertEqual(described.returncode, 0, described.stderr)


if __name__ == "__main__":
    unittest.main()
