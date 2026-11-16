# Local GUI MCP

The GUI endpoint is `http://127.0.0.1:8765/mcp`. MCP defaults off. Enable it explicitly in Settings and pass the token through the local client environment. Authentication, Origin rejection, the request budget, Agent write permissions and motor authorization are unchanged. No transport action enables writes or changes MIDI connections. The two headless services retain their own protocol and launch contracts.

## Protocol and migration

- `2026-07-28`: stateless `server/discover`, then `tools/list` / `tools/call`; no initialize or session needed. Every request includes `params._meta["io.modelcontextprotocol/protocolVersion"]`, `params._meta["io.modelcontextprotocol/clientCapabilities"]` (an object), plus matching `MCP-Protocol-Version` and `Mcp-Method` HTTP headers. `tools/call` also mirrors `params.name` in `Mcp-Name` (printable ASCII or `=?base64?<UTF-8 Base64>?=`). Successful results include `resultType: complete` and `_meta["io.modelcontextprotocol/serverInfo"]`.
- `2025-11-25`: send `initialize` with `protocolVersion`, `capabilities: {}` and `clientInfo: {name, version}`. Retain the returned `Mcp-Session-Id`, send `notifications/initialized`, then call tools with that session header and `MCP-Protocol-Version: 2025-11-25`. Maximum 32 sessions, idle expiry at 30 minutes; authenticated DELETE removes a session. Stopping the listener clears sessions.
- Build identity comes from the application bundle marketing/build versions, never a protocol constant. Direct unbundled Swift executables report `unbundled`; tests inject their build identity. No event streaming capabilities are advertised by this GUI.

This is an incompatible change from the former `2025-03-26` endpoint, including removal of JSON-RPC batches and sessionless old calls. As in BCR, a well-formed legacy initialize asking for an older or unknown version receives the supported `2025-11-25` proposal. The client must accept that negotiated version and use its handshake/headers, or disconnect. Sending `2025-03-26` for later session requests fails HTTP 400/-32602; it is not silently served under the old protocol. Unknown modern metadata versions fail HTTP 400/-32022, with `data.supported` and `data.requested`. Modern initialize is an unsupported method; use server/discover.

Requests are single JSON-RPC 2.0 objects. IDs must be strings or finite numbers (not null or booleans). Malformed JSON returns HTTP 400/-32700; invalid envelopes/batches return HTTP 400/-32600; invalid params return -32602; mismatched mirrored metadata returns HTTP 400/-32020. Unknown methods return -32601 (modern HTTP 404, legacy HTTP 200). Valid notifications return HTTP 202 without a body and never execute tool mutations. Missing/wrong tokens return 401 before protocol processing; any Origin remains rejected with 403. GET remains 405.

`tools/list` returns tools and their schemas. `tools/call` returns content/isError and structuredContent where supplied by the tool. Shared `surface_` schemas and raw result/error shapes remain unchanged; see [shared tools](SHARED_REMOTE.md). The three original GUI tools (`get_state`, `set_parameter`, `agent_primary`) retain their text result and permission/error behavior. Future aligned console tools use BCR's `{data: ...}` in text and structuredContent; tool errors use `isError: true`, `{data: {error: reason}}`. Transport/JSON-RPC errors remain distinct.

The core `MCPRouter` owns typed requests, response/error envelopes, negotiation and sessions with injected time. `LocalMCPServer` owns loopback HTTP, bearer authentication, connection bounds and the existing 60 requests/minute limit. No external runtime dependency is added.

## stdio bridge and smoke

Use only a token environment variable (never argv or a file):

```sh
export XTOUCH_MCP_TOKEN='<token copied from Settings>'
python3 tools/mcp_stdio.py --url http://127.0.0.1:8765/mcp
python3 tools/mcp_smoke.py
python3 tools/mcp_smoke.py --legacy
python3 tools/mcp_smoke.py --write --parameter a.Fader.1 --value 90
python3 tools/verify_stdio_bridge.py --url http://127.0.0.1:8765/mcp
```

Smoke defaults read-only: discover/handshake, list tools, read one parameter. `--write` writes then restores a value only after a confirmed Mock source; hardware and unknown sources are refused with a reason. An authenticated `XTouch-Source` HTTP response header reports the GUI's actual selected source. Smoke also sets `XTouch-Require-Source: mock`; the GUI checks it synchronously before tool dispatch (including restoration), rejecting a local source-switch race with HTTP 409. This is a host safety constraint, not a writable source selector or permission grant. Write/motor permissions and touch handling still use the existing route. Before aligned get_parameter/get_status tools are installed, smoke reads get_state and uses the authenticated source header; unknown sources fail closed.

CLI names match BCR: `--url`, `--token-env`, `--legacy`, `--parameter`, `--value`, with product-prefixed `XTOUCH_MCP_TOKEN` / `XTOUCH_MCP_URL`. XTouch additionally requires `--write` (BCR's probe writes by default). The bridge accepts newline JSON-RPC; stdout contains responses only. Notifications produce no line; EOF deletes legacy sessions. It handles legacy handshake and forwards modern mirrored metadata, disables proxies/redirects and accepts only IPv4 loopback HTTP `/mcp`. Diagnostics omit credentials and request/response content. Bridge verification uses the always-present get_state (BCR uses get_status).

`python3 -B -m unittest discover -s Tests/SimulatorIntegration -p test_gui_mcp.py -v` starts the Debug executable with `--integration-test --mcp-test-server` on an ephemeral port. This separate process entry creates no AppKit application/window, UserDefaults, user workspace or CoreMIDI client, and uses an in-memory token supplied by the test environment. Release refuses this entry. `--allow-writes` is an explicit isolated-test option, with motor permission still off. It exercises both protocol versions, read-only and Mock write/restore probes, and the real stdio bridge. The ordinary GUI starts with MCP/writes/motors disabled.
