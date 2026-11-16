"""Owned-process accessibility operations. No AppleScript, global input or desktop capture."""

from __future__ import annotations

import json
import os
import plistlib
import secrets
import selectors
import shutil
import subprocess
import uuid
from pathlib import Path

from tools.mcp_smoke import Client

ROOT = Path(__file__).resolve().parents[1]


class MissingPermission(RuntimeError):
    pass


class ManualRequired(RuntimeError):
    pass


def native_binary():
    source = ROOT / "tools/native_ui.swift"
    output = ROOT / "build/ui-native/native_ui"
    if not output.exists() or output.stat().st_mtime_ns < source.stat().st_mtime_ns:
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", str(source), "-o", str(output)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    return output


def preflight():
    result = subprocess.run([str(native_binary()), "--preflight"], capture_output=True, text=True, timeout=15)
    if result.returncode == 77:
        raise MissingPermission("缺权限：调用终端/Agent 未获辅助功能授权；未启动被测应用。")
    if result.returncode:
        raise RuntimeError("Accessibility preflight could not run")


class OwnedSession:
    def __init__(self, directory, binary, *, fixture=None, example=False, program=False, library=False, organize=False):
        self.directory = Path(directory).resolve()
        if (ROOT / "build").is_symlink():
            raise ValueError("Repository build root must not be a symlink")
        if not self.directory.is_relative_to((ROOT / "build").resolve()):
            raise ValueError("Acceptance artifacts must stay under repository build/")
        self.directory.mkdir(parents=True, exist_ok=True)
        self.data = self.directory / "data"
        self.data.mkdir(exist_ok=True)
        self.session = str(uuid.uuid4())
        (self.data / "ui-owner.json").write_text(json.dumps({"parent_pid": os.getpid(), "session": self.session}))
        self.log = (self.directory / "actions.jsonl").open("a")
        self.output = (self.directory / "app.log").open("w")
        self.token = secrets.token_hex(32)
        bundle = self.directory / "XTouchUIAcceptance.app"
        executable = bundle / "Contents/MacOS/XTouchCompactApp"
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, executable)
        resource = Path(binary).parent / "XTouchCompactDev_XTouchCompactLocalization.bundle"
        destination = bundle / "Contents/Resources" / resource.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(resource, destination, dirs_exist_ok=True)
        (bundle / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "dev.xtouchcompact.ui." + self.session,
                    "CFBundleExecutable": "XTouchCompactApp",
                    "CFBundlePackageType": "APPL",
                    "LSUIElement": True,
                    "LSMinimumSystemVersion": "14.0",
                }
            )
        )
        subprocess.run(
            ["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], capture_output=True, check=True
        )
        arguments = [
            str(executable),
            "--integration-test",
            "--offscreen",
            "--ui-test-server",
            "--ui-session-id",
            self.session,
        ]
        if fixture:
            if fixture in {"xtouch-long.jsonl", "xtouch-incomplete.jsonl"}:
                original = ROOT / "Tests/Fixtures/Capture/xtouch-sample.jsonl"
                rows = [json.loads(line) for line in original.read_bytes().splitlines()]
                if fixture == "xtouch-incomplete.jsonl":
                    rows = rows[:-1]
                else:
                    events = []
                    for _ in range(10):
                        for event in rows[1:-1]:
                            events.append({**event, "sequence": len(events) + 1})
                    rows = [rows[0], *events, {**rows[-1], "eventCount": len(events)}]
                (self.data / fixture).write_text("".join(json.dumps(row) + "\n" for row in rows))
            else:
                source = ROOT / "Tests/Fixtures/Capture" / fixture
                shutil.copyfile(source, self.data / fixture)
            arguments += ["--capture-fixture", fixture]
        if example:
            arguments += ["--reference-arm-example"]
        if library:
            arguments += ["--library-fixture"]
        if program:
            arguments += ["--program-fixture"]
        if organize:
            arguments += ["--organize-fixture"]
        environment = {**os.environ, "XTOUCH_UI_TOKEN": self.token, "XTOUCH_UI_DATA_DIR": str(self.data)}
        self.process = subprocess.Popen(
            arguments, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=self.output, text=True
        )
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                if not selector.select(20):
                    raise RuntimeError("Owned UI process did not become ready")
                marker = json.loads(self.process.stdout.readline())
            if marker.get("pid") != self.process.pid or marker.get("session") != self.session:
                raise RuntimeError("Owned UI ready marker mismatch")
            self.client = Client(marker["url"], self.token)
            self.check_isolation()
        except BaseException:
            self.close()
            raise

    def write_log(self, value):
        self.log.write(json.dumps(value, ensure_ascii=False) + "\n")
        self.log.flush()

    def native(self, operation, identifier="unused", value=None):
        argv = [str(native_binary()), str(self.process.pid), self.session, operation, identifier]
        if value is not None:
            argv.append(str(value))
        result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        try:
            body = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError("Owned AX helper returned no structured result") from None
        self.write_log({"operation": operation, "id": identifier, "result": body})
        if result.returncode == 77:
            raise MissingPermission("缺权限：辅助功能访问在运行中不可用。")
        if result.returncode == 78:
            raise ManualRequired(body.get("reason", body["status"]))
        if result.returncode and not (operation == "inspect" and result.returncode == 3):
            raise AssertionError(f"AX {operation} {identifier}: {body['status']}")
        return body

    def element(self, identifier):
        result = self.native("inspect", identifier)
        if result["status"] != "ok":
            raise AssertionError(f"UI identifier missing: {identifier}")
        return result["element"]

    def value(self, identifier):
        node = self.element(identifier)
        return node.get("value", node.get("title", node.get("description", "")))

    def press(self, identifier):
        self.native("press", identifier)
        self.check_isolation()

    def set(self, identifier, value):
        self.native("set", identifier, value)
        self.check_isolation()

    def query(self):
        status, result = self.client.rpc("tools/call", {"name": "integration_read_state", "arguments": {}})
        if status != 200 or "error" in result:
            raise RuntimeError("Owned read-only inspection failed")
        state = result["result"]
        self.write_log({"inspection": state})
        return state

    def check_isolation(self):
        state = self.query()
        isolated = state["isolation"]
        if (
            isolated["active"]
            or isolated["hasKeyWindow"]
            or not isolated["allTransparent"]
            or isolated.get("frontmostPID") == self.process.pid
        ):
            self.process.kill()
            raise AssertionError("Owned offscreen process violated presentation/focus isolation")
        return state

    def check(self, identifier, expected, backend_key=None):
        value = self.value(identifier)
        if str(value) != str(expected):
            raise AssertionError(f"UI {identifier}: expected {expected!r}, got {value!r}")
        if backend_key:
            state = self.query()["summary"]
            if state[backend_key] != str(expected):
                raise AssertionError(f"Model cross-check disagrees for {backend_key}")

    def capture(self, name):
        self.press("fixture.capture")
        state = self.query()
        if int(state["summary"]["snapshot.count"]) < 1:
            raise AssertionError("Owned view snapshot action did not complete")
        source = self.data / "owned-view.png"
        if not source.is_file() or source.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise AssertionError("Owned view did not render a PNG")
        shutil.copyfile(source, self.directory / (name + ".png"))

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate(timeout=5)
        self.output.close()
        self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, kind, *_):
        if kind is not None and self.process.poll() is None:
            try:
                (self.directory / "tree-final.json").write_text(json.dumps(self.native("dump"), indent=2))
            except Exception:
                pass
        self.close()
