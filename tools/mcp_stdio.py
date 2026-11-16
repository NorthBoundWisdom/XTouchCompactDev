#!/usr/bin/env python3
"""Bridge newline-delimited MCP stdio to localhost HTTP; token via XTOUCH_MCP_TOKEN."""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

CURRENT = "2026-07-28"
LEGACY = "2025-11-25"
LIMIT = 1_048_576


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def local_opener(url, token):
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.username
        or parsed.password
        or parsed.path != "/mcp"
        or parsed.query
        or parsed.fragment
        or parsed.port == 0
    ):
        raise ValueError("MCP requires an http://127.0.0.1:<port>/mcp endpoint")
    if not token or any(c in token for c in "\r\n"):
        raise ValueError("MCP token environment variable is missing or invalid")
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


class Bridge:
    def __init__(self, url, token):
        self.opener = local_opener(url, token)
        self.url, self.token = url, token
        self.session = None
        self.protocol = LEGACY

    def exchange(self, message):
        params = message.get("params", {})
        meta = params.get("_meta", {}) if isinstance(params, dict) else {}
        modern = isinstance(meta, dict) and "io.modelcontextprotocol/protocolVersion" in meta
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.protocol,
        }
        if modern:
            headers["MCP-Protocol-Version"] = meta["io.modelcontextprotocol/protocolVersion"]
            headers["Mcp-Method"] = message["method"]
            if message["method"] == "tools/call":
                headers["Mcp-Name"] = params.get("name", "")
        elif self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(
            self.url, json.dumps(message, allow_nan=False).encode(), headers, method="POST"
        )
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            if response.headers.get("Mcp-Session-Id"):
                self.session = response.headers["Mcp-Session-Id"]
            body = response.read(LIMIT + 1)
            if len(body) > LIMIT:
                raise RuntimeError("MCP response exceeds 1 MiB")
            if not body:
                if response.code >= 400:
                    raise RuntimeError("Local MCP HTTP request failed")
                return None
            result = json.loads(body)
            if not isinstance(result, dict) or result.get("jsonrpc") != "2.0":
                raise RuntimeError("Invalid MCP response")
            if message.get("method") == "initialize":
                self.protocol = result.get("result", {}).get("protocolVersion", self.protocol)
            return result

    def close(self):
        if not self.session:
            return
        request = urllib.request.Request(
            self.url,
            headers={
                "Authorization": "Bearer " + self.token,
                "MCP-Protocol-Version": self.protocol,
                "Mcp-Session-Id": self.session,
            },
            method="DELETE",
        )
        with self.opener.open(request, timeout=5):
            pass
        self.session = None


def serve(bridge, source, destination):
    while True:
        line = source.readline(LIMIT + 2)
        if not line:
            return
        if len(line.encode()) > LIMIT:
            raise ValueError("MCP input exceeds 1 MiB")
        if not line.strip():
            continue
        message = None
        try:
            message = json.loads(line)
            if (
                not isinstance(message, dict)
                or message.get("jsonrpc") != "2.0"
                or not isinstance(message.get("method"), str)
            ):
                raise ValueError("Invalid JSON-RPC request")
            result = bridge.exchange(message)
        except (ValueError, RuntimeError, urllib.error.URLError, TimeoutError):
            result = {
                "jsonrpc": "2.0",
                "id": message.get("id") if isinstance(message, dict) else None,
                "error": {"code": -32603, "message": "Local MCP request failed"},
            }
        if result is not None and (not isinstance(message, dict) or "id" in message):
            destination.write(json.dumps(result, ensure_ascii=False, allow_nan=False) + "\n")
            destination.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765/mcp")
    args = parser.parse_args()
    bridge = Bridge(args.url, os.environ.get("XTOUCH_MCP_TOKEN", ""))
    try:
        serve(bridge, sys.stdin, sys.stdout)
    finally:
        bridge.close()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, urllib.error.URLError, TimeoutError):
        print("Local MCP bridge stopped: check endpoint, credentials and server status.", file=sys.stderr)
        sys.exit(1)
