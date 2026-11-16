#!/usr/bin/env python3
"""Read-only MCP probe; --write explicitly permits one parameter write on a confirmed Mock source."""

import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request

try:
    from .mcp_stdio import CURRENT, LEGACY, LIMIT, local_opener
except ImportError:
    from mcp_stdio import CURRENT, LEGACY, LIMIT, local_opener


class Client:
    def __init__(self, url, token, legacy=False):
        self.url, self.token, self.legacy = url, token, legacy
        self.opener = local_opener(url, token)
        self.session = None
        self.request_id = 0
        self.source = None
        self.require_mock = False

    def rpc(self, method, params=None, notification=False):
        self.request_id += 1
        params = dict(params or {})
        version = LEGACY if self.legacy else CURRENT
        if not self.legacy:
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": CURRENT,
                "io.modelcontextprotocol/clientCapabilities": {},
            }
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            message["id"] = self.request_id
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": version,
        }
        if not self.legacy:
            headers["Mcp-Method"] = method
            if method == "tools/call":
                headers["Mcp-Name"] = params["name"]
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        if self.require_mock:
            headers["XTouch-Require-Source"] = "mock"
        request = urllib.request.Request(
            self.url, json.dumps(message, allow_nan=False).encode(), headers, method="POST"
        )
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            self.source = response.headers.get("XTouch-Source")
            if response.headers.get("Mcp-Session-Id"):
                self.session = response.headers["Mcp-Session-Id"]
            data = response.read(LIMIT + 1)
            if len(data) > LIMIT:
                raise RuntimeError("MCP response exceeds 1 MiB")
            reply = json.loads(data) if data else {}
            if not notification and reply.get("id") != self.request_id:
                raise RuntimeError("MCP response ID does not match")
            return response.code, reply

    def call(self, name, args=None):
        status, reply = self.rpc("tools/call", {"name": name, "arguments": args or {}})
        if status != 200 or "error" in reply or reply.get("result", {}).get("isError"):
            raise RuntimeError("MCP tool call failed")
        result = reply["result"]
        structured = result.get("structuredContent")
        if structured is None:
            structured = json.loads(result["content"][0]["text"])
        return structured.get("data", structured)

    def close(self):
        if not self.session:
            return
        request = urllib.request.Request(
            self.url,
            headers={
                "Authorization": "Bearer " + self.token,
                "MCP-Protocol-Version": LEGACY,
                "Mcp-Session-Id": self.session,
            },
            method="DELETE",
        )
        with self.opener.open(request, timeout=5):
            pass
        self.session = None


def probe(client, parameter, value, write=False):
    try:
        if client.legacy:
            status, reply = client.rpc(
                "initialize",
                {
                    "protocolVersion": LEGACY,
                    "capabilities": {},
                    "clientInfo": {"name": "xtouch-generic-smoke", "version": "1.0"},
                },
            )
            if status != 200 or reply.get("result", {}).get("protocolVersion") != LEGACY or not client.session:
                raise RuntimeError("Legacy initialization failed")
            if client.rpc("notifications/initialized", notification=True)[0] != 202:
                raise RuntimeError("Initialized notification failed")
        else:
            status, reply = client.rpc("server/discover")
            if status != 200 or CURRENT not in reply.get("result", {}).get("supportedVersions", []):
                raise RuntimeError("Modern capability discovery failed")
        status, reply = client.rpc("tools/list")
        names = {item["name"] for item in reply.get("result", {}).get("tools", [])}
        if status != 200 or not {"get_state", "set_parameter"}.issubset(names):
            raise RuntimeError("Tool discovery failed")

        def read():
            if "get_parameter" in names:
                return client.call("get_parameter", {"id": parameter})["value"]
            return client.call("get_state")["values"][parameter]

        original = read()
        if write:
            # No source observation means no write. Never infer source from a product/tool name.
            source = client.call("get_status").get("source") if "get_status" in names else client.source
            if source != "mock":
                raise RuntimeError(
                    "Write refused: a confirmed Mock source is required; hardware or unknown source is read-only"
                )
            client.require_mock = True
            try:
                result = client.call("set_parameter", {"id": parameter, "value": value})
                if result["value"] != read():
                    raise RuntimeError("Parameter readback differs from actual written value")
            finally:
                # A source switch while probing must also prevent the restoration write.
                # The server checks the required source synchronously with dispatch,
                # including the restoration, so a concurrent local switch cannot race us.
                client.call("set_parameter", {"id": parameter, "value": original})
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765/mcp")
    parser.add_argument("--token-env", default="XTOUCH_MCP_TOKEN")
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--parameter", default="a.Fader.1")
    parser.add_argument("--value", type=float, default=90)
    parser.add_argument(
        "--write", action="store_true", help="write and restore a parameter, only on a confirmed Mock source"
    )
    args = parser.parse_args()
    if not math.isfinite(args.value):
        parser.error("--value must be finite")
    token = os.environ.get(args.token_env, "")
    if not token:
        parser.error("set the token environment variable; credentials are never accepted in argv or printed")
    probe(Client(args.url, token, args.legacy), args.parameter, args.value, args.write)
    print(
        f"MCP {LEGACY if args.legacy else CURRENT}: discovery, tools, parameter read{' and Mock write/restore' if args.write else ''} passed."
    )


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(f"MCP smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, urllib.error.URLError, TimeoutError) as error:
        # Domain messages are fixed strings, never server content, headers or credentials.
        print(f"MCP smoke failed: {type(error).__name__}; check endpoint, source and permissions.", file=sys.stderr)
        sys.exit(1)
