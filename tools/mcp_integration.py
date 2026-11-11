#!/usr/bin/env python3
"""Exercise an explicitly enabled local MCP server; token is read from the environment."""

import json
import os
import urllib.request

endpoint = "http://127.0.0.1:8765/mcp"
for index, method in enumerate(["initialize", "tools/list"], 1):
    payload = {"jsonrpc": "2.0", "id": index, "method": method}
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": "Bearer " + os.environ["XTOUCH_MCP_TOKEN"],
        },
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        result = json.load(response)
        assert result["id"] == index and "result" in result, result
print("Local MCP initialization and tool discovery passed.")
