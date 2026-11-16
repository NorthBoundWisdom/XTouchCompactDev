#!/usr/bin/env python3
"""Real packaged binary + loopback HTTP in immutable device-access-disabled mode.

This is diagnostic transport evidence, never connected-controller qualification.
The shared capture tool is read-only; explicit refusal probes are a separate section.
"""

import argparse
import hashlib
import importlib
import json
import os
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path

# Checks below rely on assert; refuse to run where python -O would strip them.
try:
    from .surface_sdk_metadata import package_sdk
except ImportError:
    from surface_sdk_metadata import package_sdk


if not __debug__:
    raise SystemExit("Run without -O: these checks rely on assert")


@contextmanager
def anonymous_token_pipe(token):
    """One fresh pipe per consumer. /dev/fd/N is a public descriptor path, not a disk file."""
    read_fd, write_fd = os.pipe()
    try:
        try:
            os.write(write_fd, token.encode())
        finally:
            os.close(write_fd)
        yield read_fd
    finally:
        os.close(read_fd)


class RunningOfflineHardware:
    def __init__(self, binary, directory, instance="offline.hardware", feedback=True):
        self.directory = Path(directory)
        self.ready_path = self.directory / "ready.json"
        self.log_path = self.directory / "device-access.jsonl"
        self.stdout_path = self.directory / "stdout.jsonl"
        self.token = secrets.token_hex(32)
        arguments = [
            str(Path(binary).resolve()),
            "--device-access",
            "disabled",
            "--receive-channel",
            "2",
            "--light-protocol",
            "observed114",
            "--surface-instance-id",
            instance,
            "--port",
            "0",
            "--token-stdin",
            "--ready-file",
            str(self.ready_path),
        ]
        if feedback:
            arguments.append("--allow-surface-feedback")
        self.environment = dict(os.environ)
        self.environment.pop("XTOUCH_HARDWARE_TEST_SCRIPT", None)
        self.environment.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
        self._log = self.log_path.open("w")
        self._stdout = self.stdout_path.open("w")
        self.process = subprocess.Popen(
            arguments,
            cwd=directory,
            env=self.environment,
            stdin=subprocess.PIPE,
            stdout=self._stdout,
            stderr=self._log,
            text=True,
        )
        self.process.stdin.write(self.token + "\n")
        self.process.stdin.close()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.ready_path.exists():
                try:
                    self.ready = json.loads(self.ready_path.read_text())
                    break
                except json.JSONDecodeError:
                    pass
            if self.process.poll() is not None:
                self.close()
                raise RuntimeError("Offline service exited before readiness")
            time.sleep(0.01)
        else:
            self.close()
            raise RuntimeError("Offline service readiness timeout")
        self.instance = instance
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        assert self.ready["device_access"] == "disabled" and self.ready["diagnostic_only"] is True
        assert self.ready["test_only"] is False and all(value == 0 for value in self.ready["device_io"].values())
        assert self.token not in self.ready_path.read_text()

    def rpc(self, envelope, *, token=None, origin=None):
        headers = {
            "Authorization": "Bearer " + (self.token if token is None else token),
            "Content-Type": "application/json",
        }
        if origin:
            headers["Origin"] = origin
        request = urllib.request.Request(self.ready["url"], json.dumps(envelope).encode(), headers)
        with self.opener.open(request, timeout=5) as response:
            return json.load(response)

    def tool(self, name, arguments=None, **options):
        return self.rpc(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments or {}}},
            **options,
        )["result"]

    def close(self, termination=signal.SIGTERM):
        if self.process.poll() is None:
            self.process.send_signal(termination)
            self.process.wait(timeout=5)
        self._log.close()
        self._stdout.close()

    def audit(self):
        rows = [json.loads(line) for line in self.log_path.read_text().splitlines() if line]
        assert rows and rows[0]["event"] == "device_access_startup"
        assert rows[-1]["event"] == "device_access_disabled_cleanup"
        assert all(row["device_access"] == "disabled" and row["diagnostic_only"] is True for row in rows)
        assert all(all(value == 0 for value in row["device_io"].values()) for row in rows)
        assert self.token not in self.log_path.read_text() + self.stdout_path.read_text()
        return {
            "records": len(rows),
            "startup_records": sum(row["event"] == "device_access_startup" for row in rows),
            "request_records": sum(row["event"] == "device_access_request_complete" for row in rows),
            "cleanup_records": sum(row["event"] == "device_access_disabled_cleanup" for row in rows),
            "device_io": rows[-1]["device_io"],
        }


def verify(directory, evidence):
    directory = Path(directory).resolve()
    evidence = Path(evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    binary = directory / "XTouchSurfaceHardware"
    sdk_zip, sdk_version = package_sdk(directory)
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for name, digest in manifest["files_sha256"].items():
        relative = Path(name)
        assert not relative.is_absolute() and ".." not in relative.parts
        assert hashlib.sha256((directory / relative).read_bytes()).hexdigest() == digest
    assert "surface_control" not in sys.modules
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(sdk_zip))
    sdk = importlib.import_module("surface_control")
    assert str(sdk.__file__).startswith(str(sdk_zip) + "/") and sdk.__version__ == sdk_version
    readonly = []
    refusals = []
    lifecycle = []
    with tempfile.TemporaryDirectory(prefix="offline-hardware-", dir=evidence) as temporary:
        temporary = Path(temporary)
        process_root = temporary / "process-1"
        process_root.mkdir()
        host = RunningOfflineHardware(binary, process_root)
        try:
            client = sdk.Client(host.ready["url"], host.token, host.instance, accepted_sources=("hardware",))
            discovery = client.discover(
                versions=("1.4",), profiles=(manifest["profile_id"],), profile_versions=(manifest["profile_version"],)
            )
            assert discovery["source"] == "hardware" and discovery["latest_sequence"] == "0"
            assert all(row["accepts_input"] is False for row in discovery["profile"]["controls"])
            readonly.append({"check": "packaged-sdk-explicit-hardware-discover", "pass": True})
            snapshot = client.snapshot()
            assert (
                snapshot["link"] == {"state": "disconnected"}
                and snapshot["inputs"] == {}
                and snapshot["feedback"] == {}
            )
            readonly.append({"check": "snapshot-disconnected-and-unknown", "pass": True})
            page = client.call(
                "surface_control_events",
                {"instance_id": host.instance, "epoch": client.expected["epoch"], "after_sequence": "0", "limit": 100},
            )
            assert page["link"] == {"state": "disconnected"} and page["events"] == [] and page["latest_sequence"] == "0"
            readonly.append({"check": "events-disconnected-empty-zero-sequence", "pass": True})
            tools = host.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
            assert len(tools) == 7 and not any("device_access" in row["name"] for row in tools)
            readonly.append({"check": "no-device-access-switch-api", "pass": True})
            try:
                sdk.Client(host.ready["url"], host.token, host.instance).discover()
                raise AssertionError("Default SDK must refuse hardware")
            except sdk.SurfaceError as error:
                assert error.code == "unsupported_contract"
            readonly.append({"check": "default-sdk-hardware-fail-closed", "pass": True})
            try:
                sdk.EventCursor(client).bootstrap(snapshot)
                raise AssertionError("Disconnected cursor must fail closed")
            except sdk.SurfaceError as error:
                assert error.code == "link_disconnected"
            readonly.append({"check": "disconnected-cursor-fail-closed", "pass": True})
            for token, origin, status, label in [
                ("invalid-token", None, 401, "invalid-token"),
                (host.token, "https://example.invalid", 403, "browser-origin"),
            ]:
                try:
                    host.tool("surface_control_discover", token=token, origin=origin)
                    raise AssertionError("HTTP admission must reject")
                except urllib.error.HTTPError as error:
                    assert error.code == status
                    error.close()
                refusals.append({"check": label, "status": status, "pass": True, "scope": "http-admission"})
            expected = dict(client.expected)
            probes = [
                (
                    "input",
                    {
                        "expected": expected,
                        "expected_sequence": "0",
                        "control_id": "b.fader.1",
                        "encoding": "scalar",
                        "value": 127,
                    },
                    "permission_denied",
                ),
                ("renew", {"expected": expected, "control_id": "b.button.1", "hold_s": 1}, "unsupported_hold"),
                ("reset", {"expected": expected, "expected_sequence": "0"}, "unsupported_tool"),
                (
                    "feedback",
                    {"expected": expected, "control_id": "b.encoder.1", "kind": "value", "value": 13},
                    "invalid_transition",
                ),
            ]
            for tool, arguments, code in probes:
                result = host.tool("surface_control_" + tool, arguments)
                assert result["isError"] is True and result["structuredContent"]["code"] == code
                refusals.append(
                    {
                        "check": "surface_control_" + tool,
                        "code": code,
                        "pass": True,
                        "scope": "explicit-rejected-tool-probe",
                    }
                )
            after = client.snapshot()
            assert after["inputs"] == {} and after["feedback"] == {} and after["discovery"]["latest_sequence"] == "0"
            assert after["discovery"]["expected"] == expected and after["link"]["state"] == "disconnected"
            readonly.append({"check": "rejected-probes-preserve-identity-state-and-sequences", "pass": True})
            # The shared tool never submits writes. Disconnected is an expected nonzero capture.
            capture = evidence / "disconnected-capture.json"
            capture_report = evidence / "disconnected-verification.json"
            environment = {**host.environment, "PYTHONPATH": str(sdk_zip)}
            before_capture = len(host.log_path.read_text().splitlines())
            with anonymous_token_pipe(host.token) as token_fd:
                completed = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        "-m",
                        "surface_control_diagnostics",
                        "capture",
                        "--url",
                        host.ready["url"],
                        "--token-file",
                        "/dev/fd/" + str(token_fd),
                        "--instance-id",
                        host.instance,
                        "--profile-id",
                        manifest["profile_id"],
                        "--profile-version",
                        manifest["profile_version"],
                        "--output",
                        str(capture),
                        "--accept-hardware",
                        "--max-polls",
                        "1",
                    ],
                    pass_fds=(token_fd,),
                    cwd=temporary,
                    env=environment,
                    text=True,
                    capture_output=True,
                    timeout=30,
                )
            assert completed.returncode == 1 and capture.is_file()
            recorded = json.loads(capture.read_text())
            assert recorded["snapshot"]["link"]["state"] == "disconnected"
            assert (
                recorded["pages"] == []
                and recorded["end"]["reason"] == "link_disconnected"
                and recorded["end"]["exit_code"] == 1
            )
            capture_rows = [json.loads(line) for line in host.log_path.read_text().splitlines()[before_capture:]]
            capture_tools = [
                row.get("operation") for row in capture_rows if row.get("operation", "").startswith("surface_control_")
            ]
            assert capture_tools and set(capture_tools) <= {
                "surface_control_discover",
                "surface_control_snapshot",
                "surface_control_events",
            }
            before_verify = host.log_path.read_text()
            assert host.token not in completed.stdout + completed.stderr + capture.read_text()
            verified = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    "-m",
                    "surface_control_diagnostics",
                    "verify",
                    "--capture",
                    str(capture),
                    "--report",
                    str(capture_report),
                ],
                cwd=temporary,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            assert verified.returncode == 1 and capture_report.is_file()
            report = json.loads(capture_report.read_text())
            assert (
                report["capture_integrity"] == "verified_recorded_invariants"
                and report["diagnostic_status"] == "incomplete_or_failed"
            )
            assert report["termination"] == "link_disconnected" and report["source"] == "hardware"
            assert report["authenticity_verified"] is False and report["physical_qualification"] is False
            assert host.log_path.read_text() == before_verify
            assert host.token not in verified.stdout + verified.stderr + capture_report.read_text()
            diagnostics = {
                "capture_exit_code": completed.returncode,
                "verify_exit_code": verified.returncode,
                "capture_path": str(capture),
                "verification_path": str(capture_report),
                "expected_state": "disconnected",
                "scope": "shared-read-only-capture-no-write-tools",
                "observed_surface_tools": capture_tools,
                "capture_integrity": report["capture_integrity"],
                "diagnostic_status": report["diagnostic_status"],
                "termination": report["termination"],
                "offline_verify_admitted_rpc_records": 0,
            }
            (evidence / "shared-diagnostics-cli.json").write_text(json.dumps(diagnostics, indent=2) + "\n")
        finally:
            host.close()
        assert not host.ready_path.exists()
        audit = host.audit()
        (evidence / "process-1-device-access.jsonl").write_text(host.log_path.read_text())
        lifecycle.append(
            {
                "check": "SIGTERM-owned-ready-cleanup",
                "pass": True,
                "return_code": host.process.returncode,
                "audit": audit,
            }
        )
        process_root = temporary / "process-2"
        process_root.mkdir()
        replacement = RunningOfflineHardware(binary, process_root, instance=host.instance)
        try:
            result = replacement.tool("surface_control_discover")["structuredContent"]
            assert result["expected"]["epoch"] != expected["epoch"]
            stale = replacement.tool(
                "surface_control_events",
                {"instance_id": host.instance, "epoch": expected["epoch"], "after_sequence": "0", "limit": 100},
            )
            assert stale["isError"] is True and stale["structuredContent"]["code"] == "stale_epoch"
            snapshot = replacement.tool("surface_control_snapshot", {"instance_id": host.instance})["structuredContent"]
            assert snapshot["inputs"] == {} and snapshot["link"]["state"] == "disconnected"
        finally:
            replacement.close(signal.SIGINT)
        assert not replacement.ready_path.exists()
        second_audit = replacement.audit()
        (evidence / "process-2-device-access.jsonl").write_text(replacement.log_path.read_text())
        lifecycle.append(
            {
                "check": "new-process-new-epoch-SIGINT-ready-cleanup",
                "pass": True,
                "return_code": replacement.process.returncode,
                "audit": second_audit,
            }
        )
    report = {
        "scope": "outside-source-real-loopback-device-access-disabled",
        "source": "hardware",
        "device_access": "disabled",
        "diagnostic_only": True,
        "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "read_only_checks": readonly,
        "refusal_probes": refusals,
        "lifecycle_checks": lifecycle,
        "shared_diagnostics": diagnostics,
        "counts": {
            "read_only_pass": len(readonly),
            "refusal_pass": len(refusals),
            "lifecycle_pass": len(lifecycle),
            "fail": 0,
        },
        "hardware_connected": False,
        "midi_access": False,
        "accepted_writes": 0,
        "physical_qualification": False,
    }
    (evidence / "http-verification.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("delivery", type=Path)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.delivery, args.evidence), sort_keys=True))
