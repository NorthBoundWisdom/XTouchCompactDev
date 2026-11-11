#!/usr/bin/env python3
"""Exercise an explicitly enabled local MCP server; token is read from the environment."""

import json
import os
import urllib.request


def main() -> None:
    token = os.environ.get("XTOUCH_MCP_TOKEN")
    if not token:
        raise ValueError("Set XTOUCH_MCP_TOKEN to the explicitly enabled server token.")
    endpoint = "http://127.0.0.1:8765/mcp"
    for index, method in enumerate(["initialize", "tools/list"], 1):
        payload = {"jsonrpc": "2.0", "id": index, "method": method}
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(payload).encode(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Authorization": "Bearer " + token,
            },
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            result = json.load(response)
            if not isinstance(result, dict) or result.get("id") != index or "result" not in result or "error" in result:
                raise ValueError(f"Invalid MCP response to {method}.")
    print("Local MCP initialization and tool discovery passed.")


if __name__ == "__main__":
    main()
