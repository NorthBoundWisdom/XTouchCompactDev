"""One real legacy MCP action, upstream success, then downstream response loss. No credential files."""

import http.server
import json
import socket
import sys
import threading
import urllib.error
import urllib.request

config = json.load(sys.stdin)
sys.dont_write_bytecode = True
sys.path.insert(0, config["sdk"])
from surface_control import Client, SurfaceError

state = {"proxy_requests": 0, "upstream_successes": 0, "actual_tool": None}


class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        state["proxy_requests"] += 1
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        call = json.loads(raw)
        state["actual_tool"] = call.get("params", {}).get("name")
        # Preserve the SDK's actual end-to-end protocol metadata. Never invent mirrored
        # values to satisfy the upstream router; only transport hop headers are removed.
        hop_headers = {
            "host",
            "content-length",
            "connection",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        }
        headers = {name: value for name, value in self.headers.items() if name.lower() not in hop_headers}
        request = urllib.request.Request(
            "http://127.0.0.1:" + str(config["port"]) + "/mcp",
            raw,
            headers,
        )
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=3) as response:
                state["upstream_http_status"] = response.status
                result = json.load(response)
            state["upstream_successes"] += int("result" in result and "error" not in result)
        except urllib.error.HTTPError as error:
            state["upstream_http_status"] = error.code
            try:
                state["upstream_rpc_error_code"] = json.load(error).get("error", {}).get("code")
            finally:
                error.close()
        self.close_connection = True
        self.connection.shutdown(socket.SHUT_RDWR)
        self.connection.close()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
client = Client(
    "http://127.0.0.1:" + str(server.server_port) + "/mcp",
    config["token"],
    "h10.gui.mock",
    protocol="2026-07-28",
    timeout=3,
)
code = None
try:
    client.rpc("tools/call", {"name": "agent_primary", "arguments": {"slot": 1}})
except SurfaceError as error:
    code = error.code
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
report = {
    **state,
    "client_code": code,
    "sdk_request_count": client.sequence,
    "route": "retained GUI agent_primary via actual modern stateless low-level rpc; no old-protocol negotiation claim",
}
assert config["token"] not in json.dumps(report)
print(json.dumps(report, sort_keys=True))
