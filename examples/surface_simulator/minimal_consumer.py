#!/usr/bin/env python3
"""Stdlib consumer using only a simulator delivery, never controller source code.

Read the ready JSON from stdin/file and token from a private token file. Writes
are explicit and never retried. A lost response is an unknown outcome.
"""
import argparse
import json
import urllib.request
import urllib.parse


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, new_url):
        if stream is not None:
            stream.close()
        raise RuntimeError("Redirect refused")


def call(url, token, name, arguments):
    request = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1,
        "method": "tools/call", "params": {"name": name, "arguments": arguments}}).encode(),
        {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=3) as response:
        envelope = json.load(response)
    if "error" in envelope:
        raise RuntimeError(envelope["error"])
    result = envelope["result"]
    if result["isError"]:
        raise RuntimeError(result["structuredContent"])
    return result["structuredContent"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--exercise", action="store_true", help="send one explicit simulation input and feedback")
    args = parser.parse_args()
    with open(args.ready_file, encoding="utf-8") as stream:
        ready = json.load(stream)
    with open(args.token_file, encoding="utf-8") as stream:
        token = stream.read().strip()
    url = ready["url"]
    address = urllib.parse.urlsplit(url)
    if not (address.scheme == "http" and address.hostname == "127.0.0.1" and address.port
            and address.path == "/mcp" and not address.query and not address.fragment
            and address.username is None and address.password is None):
        raise RuntimeError("Expected an explicit loopback simulation URL")
    discovery = call(url, token, "surface_control_discover", {})
    assert discovery["source"] == "simulation"
    assert (discovery["profile"]["id"], discovery["profile"]["version"]) in {
        ("xtouch.compact.standard.simulation", "1.1"), ("xtouch.compact.standard.simulation", "1.2"),
        ("bcr2000.mock", "1.0")}

    assert discovery["expected"] == ready["surface_control"]["expected"]
    snapshot = call(url, token, "surface_control_snapshot", {"instance_id": discovery["expected"]["instance_id"]})
    if args.exercise:
        control = next(control for control in discovery["profile"]["controls"]
                       if control.get("mapping", {}).get("id") == "simulation.arm")
        request = {"expected": discovery["expected"], "expected_sequence": snapshot["latest_sequence"],
            "control_id": control["id"], "encoding": control["encoding"], "value": 127}
        accepted = call(url, token, "surface_control_input", request)
        status = next(control for control in discovery["profile"]["controls"]
                      if control.get("mapping", {}).get("id") == "simulation.link")
        shown = call(url, token, "surface_control_feedback", {"expected": discovery["expected"],
            "expected_sequence": accepted["sequence"], "control_id": status["id"], "kind": "indicator", "value": "on"})
        print(json.dumps({"source": "simulation", "input": accepted, "feedback": shown}, sort_keys=True))
    else:
        print(json.dumps(snapshot, sort_keys=True))


if __name__ == "__main__":
    main()
