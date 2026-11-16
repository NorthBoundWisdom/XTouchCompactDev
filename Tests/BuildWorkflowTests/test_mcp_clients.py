"""Client safety and framing tests without user services, credentials or desktop access."""

import io
import json
import unittest
from unittest.mock import patch

from tools.mcp_smoke import probe
from tools.mcp_stdio import Bridge, NoRedirect, serve


class ProbeClient:
    legacy = False
    source = "mock"

    def __init__(self, source="mock", fail_write=False):
        self.source, self.fail_write = source, fail_write
        self.calls = []
        self.closed = False
        self.value = 12
        self.require_mock = False

    def rpc(self, method, params=None, notification=False):
        if method == "server/discover":
            return 200, {"result": {"supportedVersions": ["2026-07-28"]}}
        return 200, {"result": {"tools": [{"name": name} for name in ("get_state", "set_parameter")]}}

    def call(self, name, args=None):
        self.calls.append((name, args))
        if name == "get_state":
            return {"values": {"p": self.value}}
        if name == "set_parameter":
            if not self.require_mock or self.source != "mock":
                raise AssertionError("Write lacks atomic Mock guard")
            self.value = args["value"]
            if self.fail_write and self.value != 12:
                raise RuntimeError("failure")
            return {"value": self.value}
        raise AssertionError("Unexpected tool")

    def close(self):
        self.closed = True


class MCPClientTests(unittest.TestCase):
    def test_default_probe_is_read_only(self):
        client = ProbeClient()
        probe(client, "p", 90)
        self.assertEqual(client.calls, [("get_state", None)])
        self.assertTrue(client.closed)

    def test_write_and_restore_require_mock_and_guard_each_request(self):
        for failure in (False, True):
            client = ProbeClient(fail_write=failure)
            if failure:
                with self.assertRaises(RuntimeError):
                    probe(client, "p", 90, True)
            else:
                probe(client, "p", 90, True)
            self.assertEqual(client.value, 12)
            self.assertTrue(client.closed)

    def test_hardware_or_unknown_source_never_writes(self):
        for source in ("hardware", None, "simulation", ""):
            client = ProbeClient(source)
            with self.assertRaisesRegex(RuntimeError, "confirmed Mock source"):
                probe(client, "p", 90, True)
            self.assertEqual(client.calls, [("get_state", None)])
            self.assertTrue(client.closed)

    def test_bridge_rejects_remote_credentials_query_redirects_and_proxy(self):
        for url in (
            "https://127.0.0.1/mcp",
            "http://localhost/mcp",
            "http://remote/mcp",
            "http://user:secret@127.0.0.1/mcp",
            "http://127.0.0.1/mcp?token=secret",
            "http://127.0.0.1/mcp#secret",
            "http://127.0.0.1:0/mcp",
        ):
            with self.assertRaises(ValueError):
                Bridge(url, "memory")
        for token in ("", "x\ny", "x\ry"):
            with self.assertRaises(ValueError):
                Bridge("http://127.0.0.1:8765/mcp", token)
        with (
            patch("tools.mcp_stdio.urllib.request.build_opener"),
            patch("tools.mcp_stdio.urllib.request.ProxyHandler") as proxy,
        ):
            Bridge("http://127.0.0.1:8765/mcp", "memory")
            proxy.assert_called_once_with({})
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "http://remote"))

    def test_stdio_notifications_have_no_output_and_errors_do_not_leak_content(self):
        class FakeBridge:
            def exchange(self, message):
                raise RuntimeError("credential-and-content-must-not-escape")

        output = io.StringIO()
        serve(
            FakeBridge(),
            io.StringIO(
                '{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":7,"method":"ping"}\n{\n'
            ),
            output,
        )
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([reply["id"] for reply in replies], [7, None])
        self.assertNotIn("credential", output.getvalue())
        self.assertTrue(all(reply["error"]["code"] == -32603 for reply in replies))
