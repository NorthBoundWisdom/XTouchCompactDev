"""Exercise GUI-host routing in a Debug Mock process without AppKit, CoreMIDI or user storage."""

import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.mcp_smoke import Client, probe
from tools.verify_stdio_bridge import verify


@unittest.skipUnless(sys.platform == "darwin", "GUI host integration requires macOS")
class GUIMCPIntegrationTests(unittest.TestCase):
    def test_isolated_mock_bridge_smoke_and_atomic_source_guard(self):
        binary = os.environ.get("XTOUCH_GUI_BINARY")
        if not binary:
            output = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True,
                                    capture_output=True, timeout=20, check=True).stdout.strip()
            binary = str(Path(output.splitlines()[-1]) / "XTouchCompactApp")
        token = secrets.token_hex(32)
        environment = {**os.environ, "XTOUCH_MCP_TOKEN": token}
        process = subprocess.Popen([binary, "--integration-test", "--mcp-test-server", "--allow-writes"],
                                   cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(15), "Isolated MCP ready marker timed out")
                ready = json.loads(process.stdout.readline())
            self.assertEqual(ready["type"], "xtouch.mcp_test_ready")
            self.assertIs(ready["hardwareAccessed"], False)
            url = ready["url"]
            for legacy in (False, True):
                probe(Client(url, token, legacy), "a.Fader.1", 90)
                probe(Client(url, token, legacy), "a.Fader.1", 90, True)
            with patch.dict(os.environ, environment):
                verify(url)
            client = Client(url, token)
            client.require_mock = True
            status, reply = client.rpc("tools/call", {"name": "get_state"})
            self.assertEqual(status, 200)
            self.assertEqual(client.source, "mock")
            self.assertEqual(reply["result"]["isError"], False)
        finally:
            process.terminate()
            stdout, stderr = process.communicate(timeout=10)
            self.assertNotIn(token, stdout + stderr)
