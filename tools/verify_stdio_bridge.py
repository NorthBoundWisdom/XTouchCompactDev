#!/usr/bin/env python3
"""Check a stdio bridge against an explicitly isolated running GUI MCP endpoint."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def verify(url):
    messages = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "xtouch-stdio-acceptance", "version": "1.0"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_state", "arguments": {}}},
    ]
    result = subprocess.run(
        [sys.executable, str(Path(__file__).with_name("mcp_stdio.py")), "--url", url],
        input="".join(json.dumps(message) + "\n" for message in messages),
        capture_output=True,
        text=True,
        timeout=20,
    )
    if result.returncode:
        raise RuntimeError("stdio bridge process failed")
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    if [reply.get("id") for reply in responses] != [1, 2, 3]:
        raise RuntimeError("stdio response IDs do not match requests")
    if any("error" in reply or "result" not in reply for reply in responses):
        raise RuntimeError("stdio requests failed")
    if not responses[1]["result"].get("tools") or responses[2]["result"].get("isError"):
        raise RuntimeError("stdio discovery or read failed")
    print("stdio bridge: initialize, notification, tools, read and session cleanup passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("XTOUCH_MCP_URL", "http://127.0.0.1:8765/mcp"))
    verify(parser.parse_args().url)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired):
        print("stdio bridge verification failed; check endpoint and credentials.", file=sys.stderr)
        sys.exit(1)
