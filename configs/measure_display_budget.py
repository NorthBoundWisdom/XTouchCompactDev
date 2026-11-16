#!/usr/bin/env python3
"""Measure real Debug processes against isolated local scripted MIDI, never a real device."""

import argparse
import json
import math
import os
import secrets
import subprocess
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        "min_ms": values[0] * 1000,
        **{
            label + "_ms": values[max(0, math.ceil(q * len(values)) - 1)] * 1000
            for label, q in [("p50", 0.5), ("p95", 0.95), ("p99", 0.99)]
        },
        "max_ms": values[-1] * 1000,
    }


def validate_receipts(requests, receipts):
    """Compare the complete ordered typed plans, including payload bytes, with local receipts."""
    expected = []
    for request in requests:
        if request["result"].get("isError"):
            continue
        if request["kind"] == "value":
            expected += [("style", request["index"], 0), ("value", request["index"], request["value"])]
        else:
            # The measurement starts the existing observed114 light protocol explicitly.
            expected.append(("indicator", request["index"], {"off": 0, "on": 2, "blink": 3}[request["value"]]))
    if len(expected) != len(receipts):
        return ["Typed plan receipt count differs"]
    errors = []
    for sequence, (plan, receipt) in enumerate(zip(expected, receipts), 1):
        word = int(receipt["word"], 16)
        if (receipt["kind"], receipt["index"], word & 255) != plan or receipt["send_index"] != sequence:
            errors.append("Typed plan or send index differs at message " + str(sequence))
        status, number = (word >> 16) & 0xF0, (word >> 8) & 127
        if status not in (0x90, 0xB0) or (status == 0xB0 and 1 <= number <= 9):
            errors.append("Forbidden output in fake receipt at message " + str(sequence))
    return errors


class FakeHost:
    def __init__(self, binary, directory, configured=False, timing=True):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.script = self.directory / "test-only-inputs.json"
        self.rows = [{"connected": True}, {"bytes": [176, 1, 0]}]
        self.script.write_text(json.dumps(self.rows))
        self.receipts = self.directory / "test-only-display-receipts.jsonl"
        self.tokens = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
        env = dict(os.environ)
        env.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
        env.pop("XTOUCH_HARDWARE_TEST_TIMING", None)
        env["XTOUCH_HARDWARE_TEST_SCRIPT"] = str(self.script.resolve())
        if timing:
            env["XTOUCH_HARDWARE_TEST_TIMING"] = str(self.receipts.resolve())
        command = [
            str(Path(binary).resolve()),
            "--receive-channel",
            "2",
            "--light-protocol",
            "observed114",
            "--surface-client-tokens-stdin",
            "--surface-instance-id",
            "display.budget",
            "--allow-surface-feedback",
        ]
        if configured:
            command += ["--write-limits", "input=60,feedback=300,renew=60,admin=10"]
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=self.directory,
        )
        self.process.stdin.write(json.dumps(self.tokens))
        self.process.stdin.close()
        ready_line = self.process.stdout.readline()
        if not ready_line:
            error = self.process.stderr.read()
            self.process.wait(timeout=5)
            self.process.stdout.close()
            self.process.stderr.close()
            raise RuntimeError("Debug fake host refused startup: " + error)
        self.ready = json.loads(ready_line)
        if not self.ready.get("test_only"):
            self.close()
            raise RuntimeError("Measurement requires an explicitly test-only host")
        discovery = self.rpc("display", "discover", {})["structuredContent"]
        self.expected = discovery["expected"]
        snapshot = self.rpc("operator", "snapshot", {"instance_id": "display.budget"})["structuredContent"]
        self.cursor = snapshot["discovery"]["latest_sequence"]
        self.initial_snapshot = snapshot
        # Same-machine monotonic clocks are checked rather than assumed. A server sample must
        # lie inside its local request bounds (small allowance solely for float rounding).
        before = time.monotonic()
        sample = self.rpc("display", "snapshot", {"instance_id": "display.budget"})["structuredContent"]["server_time"]
        after = time.monotonic()
        if not before - 0.001 <= sample <= after + 0.001:
            self.close()
            raise RuntimeError("Python and Swift monotonic clocks are not in the same domain")
        (self.directory / "method.json").write_text(
            json.dumps(
                {
                    "source": "test-only hardware double",
                    "configured_feedback_per_window": 300 if configured else None,
                    "default_aggregate_per_window": None if configured else 60,
                    "window_seconds": 1,
                    "timing_capture": timing,
                    "clock_sample": {"request_start": before, "server_time": sample, "response_end": after},
                    "command_without_credentials": command,
                    "observes_real_device": False,
                },
                indent=2,
            )
            + "\n"
        )

    def rpc(self, role, operation, arguments):
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": "surface_control_" + operation, "arguments": arguments},
            }
        ).encode()
        request = urllib.request.Request(
            self.ready["url"],
            body,
            {"Authorization": "Bearer " + self.tokens[role], "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)["result"]

    def append_input(self, value):
        self.rows.append({"bytes": [176, 1, value]})
        staging = self.script.with_suffix(".next")
        staging.write_text(json.dumps(self.rows))
        started = time.monotonic()
        staging.replace(self.script)
        return started

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        stderr = self.process.stderr.read()
        self.process.stderr.close()
        (self.directory / "host-stderr.log").write_text(stderr)


def run_case(binary, output, targets, hz, seconds, configured, timing=True):
    name = ("feedback300" if configured else "default") + f"-{targets}-targets-{hz}hz"
    directory = Path(output) / name
    host = FakeHost(binary, directory, configured=configured, timing=timing)
    generated, requests, pages, errors = [], [], [], []
    gate = threading.Event()
    stop_reading = threading.Event()
    start = time.monotonic() + 0.1
    end = start + seconds

    def wait_until(deadline):
        delay = deadline - time.monotonic()
        if delay > 0:
            time.sleep(delay)

    def produce():
        try:
            gate.wait()
            for index in range(math.floor(seconds * 10)):
                wait_until(start + index / 10)
                value = (index + 1) % 128
                generated.append({"index": index, "value": value, "generated_at": host.append_input(value)})
        except Exception as error:
            errors.append("input: " + repr(error))

    def read_events():
        try:
            gate.wait()
            while not stop_reading.is_set():
                before = time.monotonic()
                result = host.rpc(
                    "operator",
                    "events",
                    {
                        "instance_id": "display.budget",
                        "epoch": host.expected["epoch"],
                        "after_sequence": host.cursor,
                        "limit": 1024,
                    },
                )
                after = time.monotonic()
                pages.append({"request_start": before, "response_end": after, "result": result})
                if result.get("isError"):
                    errors.append("events: " + result["structuredContent"]["code"])
                    break
                events = result["structuredContent"]["events"]
                if events:
                    host.cursor = events[-1]["sequence"]
                stop_reading.wait(0.05)
        except Exception as error:
            errors.append("reader: " + repr(error))

    producer = threading.Thread(target=produce)
    reader = threading.Thread(target=read_events)
    producer.start()
    reader.start()
    gate.set()
    try:
        for frame in range(math.floor(seconds * hz)):
            wait_until(start + frame / hz)
            for target in range(targets):
                ring = target < 16
                index = target + 1 if ring else target - 15
                control = ("a.encoder." if ring else "a.button.") + str(index)
                value = 1 + (frame + target) % 13 if ring else ("on" if (frame + target) % 2 else "off")
                before = time.monotonic()
                result = host.rpc(
                    "display",
                    "feedback",
                    {
                        "expected": host.expected,
                        "control_id": control,
                        "kind": "value" if ring else "indicator",
                        "value": value,
                    },
                )
                requests.append(
                    {
                        "frame": frame,
                        "target": control,
                        "kind": "value" if ring else "indicator",
                        "index": index,
                        "value": value,
                        "request_start": before,
                        "response_end": time.monotonic(),
                        "result": result,
                    }
                )
        wait_until(end)
        producer.join(timeout=5)
        # One bounded drain after the final generated input; not a retry of a failed assertion.
        time.sleep(0.1)
        stop_reading.set()
        reader.join(timeout=5)
        if producer.is_alive() or reader.is_alive():
            raise RuntimeError("Measurement worker did not finish")
        ended = time.monotonic()
        final = host.rpc("operator", "snapshot", {"instance_id": "display.budget"})
        old_cursor = host.rpc(
            "operator",
            "events",
            {"instance_id": "display.budget", "epoch": host.expected["epoch"], "after_sequence": "0", "limit": 1024},
        )
    finally:
        stop_reading.set()
        producer.join(timeout=6)
        reader.join(timeout=6)
        host.close()
    for name_part, rows in [("requests", requests), ("input-generated", generated), ("event-pages", pages)]:
        with (directory / (name_part + ".jsonl")).open("w") as destination:
            for row in rows:
                destination.write(json.dumps(row, sort_keys=True) + "\n")
    (directory / "final-snapshot.json").write_text(json.dumps(final, sort_keys=True) + "\n")
    (directory / "stale-cursor-result.json").write_text(json.dumps(old_cursor, sort_keys=True) + "\n")
    accepted = [row for row in requests if not row["result"].get("isError")]
    refused = [row for row in requests if row["result"].get("isError")]
    limited = [row for row in refused if row["result"]["structuredContent"]["code"] == "rate_limited"]
    errors += [row["result"]["structuredContent"]["code"] for row in refused if row not in limited]
    receipts = [json.loads(row) for row in host.receipts.read_text().splitlines()] if timing else []
    if timing:
        errors += validate_receipts(requests, receipts)
    expected_receipts = sum(2 if row["kind"] == "value" else 1 for row in accepted)
    latencies, offset = [], 0
    for row in accepted:
        count = 2 if row["kind"] == "value" else 1
        received = receipts[offset : offset + count]
        offset += count
        if not timing:
            continue
        kinds = ["style", "value"] if count == 2 else ["indicator"]
        if [item["kind"] for item in received] != kinds or any(item["index"] != row["index"] for item in received):
            errors.append("Fake transport lost or reordered a typed display message")
            break
        latencies.append(received[-1]["server_time"] - row["request_start"])
    if timing and len(receipts) != expected_receipts:
        errors.append("Fake receipt count differs from every accepted plan; not intentional coalescing")
    received_inputs = []
    for page in pages:
        for event in page["result"].get("structuredContent", {}).get("events", []):
            if event["kind"] == "input" and event["control_id"] == "a.fader.1":
                received_inputs.append(
                    {
                        "value": event["value"],
                        "sequence": event["sequence"],
                        "server_time": event["time"],
                        "read_at": page["response_end"],
                    }
                )
    input_latency = []
    if [row["value"] for row in received_inputs] != [row["value"] for row in generated]:
        errors.append("Input events lost/reordered under display load")
    else:
        input_latency = [
            observed["read_at"] - created["generated_at"] for created, observed in zip(generated, received_inputs)
        ]
    summary = {
        "case": name,
        "targets": targets,
        "refresh_hz": hz,
        "duration_requested_s": seconds,
        "elapsed_s": ended - start,
        "attempted": len(requests),
        "accepted": len(accepted),
        "rate_limited": len(limited),
        "coalesced": 0,
        "fake_messages": len(receipts) if timing else None,
        "expected_fake_messages": expected_receipts,
        "request_to_fake_receipt": distribution(latencies),
        "feedback_rpc_roundtrip": distribution([row["response_end"] - row["request_start"] for row in requests]),
        "input_events_generated": len(generated),
        "input_events_read": len(received_inputs),
        "input_generation_to_read": distribution(input_latency),
        "event_read_rpc_roundtrip": distribution([row["response_end"] - row["request_start"] for row in pages]),
        "event_gap_during_continuous_read": any("event_gap" in error for error in errors),
        "stale_zero_cursor_code": old_cursor.get("structuredContent", {}).get("code"),
        "errors": errors,
    }
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--configuration", choices=["default", "feedback300"], required=True)
    parser.add_argument("--targets", type=int, nargs="+", default=[8, 16, 24])
    parser.add_argument("--hz", type=int, nargs="+", default=[5, 10])
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--no-timing", action="store_true")
    args = parser.parse_args()
    if (
        not args.binary.is_file()
        or not 0 < args.seconds <= 3600
        or any(n < 0 or n > 24 for n in args.targets)
        or any(hz <= 0 or hz > 20 for hz in args.hz)
        or not 1 <= args.workers <= 6
    ):
        parser.error("Need a Debug binary, positive duration and targets 0..24")
    args.output.mkdir(parents=True, exist_ok=True)
    cases = [(count, hz) for count in args.targets for hz in args.hz]
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        results = list(
            executor.map(
                lambda case: run_case(
                    args.binary,
                    args.output,
                    *case,
                    args.seconds,
                    args.configuration == "feedback300",
                    not args.no_timing,
                ),
                cases,
            )
        )
    (args.output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    if any(result["errors"] for result in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
