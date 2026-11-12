"""Real subprocess + loopback tests; no MIDI, GUI, Pipe service, or user store."""
import json
import os
from pathlib import Path
import shutil
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
sys.path.insert(0, str(ROOT / "Clients/Python"))
from surface_control import Client, CommandCursor, SurfaceError

BINARY = Path(os.environ.get("XTOUCH_SIMULATOR_BINARY", ROOT / ".build/debug/XTouchSurfaceSimulator")).resolve()
TOKEN = "isolated-simulation-test-token"


class RunningSimulator:
    def __init__(self, directory, instance=None, mutations=True, port=0):
        self.directory = Path(directory)
        binary = self.directory / "XTouchSurfaceSimulator"
        if not binary.exists():
            shutil.copy2(BINARY, binary)
        command = [str(binary), "--token-stdin", "--port", str(port)]
        if instance is not None:
            command += ["--surface-instance-id", instance]
        if mutations:
            command += ["--allow-surface-input", "--allow-surface-feedback", "--allow-surface-reset"]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, cwd=self.directory)
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
        data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": args or {}}}).encode()
        headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
        if origin:
            headers["Origin"] = origin
        request = urllib.request.Request(self.ready["url"], data, headers)
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)["result"]

    def discover(self):
        return self.request("surface_control_discover")["structuredContent"]

    def snapshot(self):
        return self.request("surface_control_snapshot", {"instance_id": self.ready["surface_control"]["expected"]["instance_id"]})["structuredContent"]

    def input(self, value=127):
        discovery = self.discover()
        return {"expected": discovery["expected"], "expected_sequence": discovery["latest_sequence"],
            "control_id": "a.encoder.1", "encoding": "scalar", "value": value}


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
        self.assertEqual(len(discovery["profile"]["controls"]), 178)
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


if __name__ == "__main__":
    unittest.main()
