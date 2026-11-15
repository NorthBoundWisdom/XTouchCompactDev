#!/usr/bin/env python3
"""Prepare/operate the isolated attended checklist; rehearsal uses only scripted MIDI."""

import argparse
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve()
ROOT = HERE.parents[1] if HERE.parent.name == "configs" else HERE.parents[3] / "XTouchCompactDev"
OUT = ROOT.parent / "build/e"
WORK = OUT / "xtouch"
RUNTIME = WORK / "runtime"
sys.dont_write_bytecode = True

# Checks below rely on assert; refuse to run where python -O would strip them.
if not __debug__:
    raise SystemExit("Run without -O: these checks rely on assert")
sys.path.insert(0, str(ROOT / "build/dependencies/SurfacePlugins/clients/python"))
from surface_control import Client


def steps():
    descriptions = [
        (
            "E-C-1",
            "start-readonly",
            False,
            "请双手离开控制台；查看A/B层键的指示，不要通过软件换层。",
            "无",
            "启动实体服务并确认connected、输入未知、发送0",
            None,
        ),
        (
            "E-C-2",
            "observe",
            False,
            "先看A/B层指示，再推第1根推子、轻触并松开、转第1编码器、按下松开第1按键；全程保持同一层。",
            "依提示操作四类输入",
            "各自带实际层ID、source/origin hardware、序号连续",
            "设备显示在哪一层？",
        ),
        (
            "E-C-3",
            "mark",
            False,
            "现在记录旧代次；随后请拔下USB，等待3秒再插回，暂不动任何控件。",
            "拔USB、等待3秒、插回",
            "保存旧epoch和事件游标",
            None,
        ),
        (
            "E-C-4",
            "replug",
            False,
            "请确认USB已插回，暂不动控件。",
            "手离开",
            "旧代次stale_epoch、新代次输入未知、无重放、发送0",
            None,
        ),
        (
            "E-C-5",
            "start-displays",
            False,
            "即将重启并开放显示权限；启动本身不会发送。请再操作第1编码器，以取得当前层输入证据。",
            "重启后转第1编码器",
            "启动发送0，等待当前层证据",
            None,
        ),
        (
            "E-C-6",
            "button",
            True,
            "即将点亮最近输入层的第2按键灯。请确认可以发送这次显示反馈。",
            "观察按键灯",
            "仅1条按键灯消息，电机CC与Program Change均0",
            "亮的是哪个按键？",
        ),
        (
            "E-C-7",
            "ring",
            True,
            "即将设置最近输入层的第1编码器灯环。请确认可以发送这次显示反馈。",
            "观察灯环",
            "仅灯环样式与显示，电机CC与Program Change均0",
            "亮的是哪个灯环？",
        ),
        (
            "E-C-8",
            "check",
            False,
            "请回想整个过程里推子是否曾自己移动；软件只发送显示消息。",
            "观察并回答",
            "显示事件与输入独立；全过程无电机CC与Program Change",
            "整个过程里推子有没有自己动过？",
        ),
        ("E-C-9", "stop", False, "停止隔离服务。", "无", "仅停止本脚本所属进程；退出无发送", None),
    ]
    result = []
    for identity, command, sends, say, action, check, ask in descriptions:
        result.append(
            {
                "id": identity,
                "sends_to_device": sends,
                "moves_motors": False,
                "command": f"python3 build/e/xtouch/field.py {command}" + (" --confirmed" if sends else ""),
                "say_before": say,
                "confirm_before": "用户刚确认本次显示发送" if sends else None,
                "user_action": action,
                "ask": ask,
                "expected_answer": "第2按键"
                if command == "button"
                else ("第1编码器灯环" if command == "ring" else ("没有" if command == "check" else None)),
                "auto_check": check,
                "on_fail": "停止后续发送，记录原始结果；不自动重试、不猜测层、不软件换层",
            }
        )
    return result


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    document = {
        "schema_version": 1,
        "device": "XTouch Compact",
        "qualification": "pending attended acceptance; fake rehearsal is not hardware evidence",
        "steps": steps(),
    }
    (OUT / "xtouch-attended.json").write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    lines = [
        "# XTouch E轮现场清单",
        "",
        "替身演练不构成实机验收。agent操作软件，用户只观察和动硬件。",
        "",
        "```json",
        json.dumps(document, ensure_ascii=False, indent=2),
        "```",
        "",
    ]
    (OUT / "xtouch-attended.md").write_text("\n".join(lines))
    destination = WORK / "field.py"
    if destination != HERE:
        shutil.copy2(HERE, destination)
    return {
        "steps": len(document["steps"]),
        "sends": sum(row["sends_to_device"] for row in document["steps"]),
        "moves_motors": sum(row["moves_motors"] for row in document["steps"]),
    }


def rehearse():
    import tempfile

    sys.path.insert(0, str(ROOT / "Tests/SimulatorIntegration"))
    from test_hardware_service import RunningHardware

    records = []
    with tempfile.TemporaryDirectory(prefix="xtouch-e-rehearsal-") as scratch:
        host = RunningHardware(scratch, feedback=False)
        try:
            assert host.client.snapshot()["inputs"] == {} and host.output()["sent_count"] == 0
            records.append({"id": "E-C-1", "pass": True, "sent": 0})
            snapshot = host.append(
                {"bytes": [176, 28, 64]},
                {"bytes": [176, 111, 127]},
                {"bytes": [176, 111, 0]},
                {"bytes": [176, 37, 64]},
                {"bytes": [144, 71, 127]},
                {"bytes": [128, 71, 0]},
            )
            assert snapshot["inputs"]["b.fader.1"] == 64 and snapshot["inputs"]["b.touch.1"] is False
            events = host.raw(
                "surface_control_events",
                {
                    "instance_id": "hardware.test",
                    "epoch": host.client.expected["epoch"],
                    "after_sequence": "0",
                    "limit": 100,
                },
            )["structuredContent"]["events"]
            assert [row["sequence"] for row in events] == [str(n) for n in range(1, 7)]
            assert all(row["source"] == row["origin"] == "hardware" for row in events)
            records.append({"id": "E-C-2", "pass": True, "sent": 0})
            old = host.client.expected
            records.append({"id": "E-C-3", "pass": True, "sent": 0})
            host.append({"connected": False}, {"bytes": [176, 28, 20]}, {"connected": True})
            assert (
                host.raw(
                    "surface_control_events",
                    {"instance_id": "hardware.test", "epoch": old["epoch"], "after_sequence": "0", "limit": 100},
                )["structuredContent"]["code"]
                == "stale_epoch"
            )
            host.client = Client(host.ready["url"], host.token, "hardware.test", accepted_sources=("hardware",))
            host.discover()
            assert host.client.snapshot()["inputs"] == {} and host.output()["sent_count"] == 0
            records.append({"id": "E-C-4", "pass": True, "sent": 0})
        finally:
            host.close()
    with tempfile.TemporaryDirectory(prefix="xtouch-e-display-rehearsal-") as scratch:
        host = RunningHardware(scratch, feedback=True)
        try:
            assert host.output()["sent_count"] == 0
            host.append({"bytes": [176, 37, 64]})
            records.append({"id": "E-C-5", "pass": True, "sent": 0})
            host.client.feedback("b.button.2", "indicator", "on")
            assert host.output()["sent_count"] == 1
            records.append({"id": "E-C-6", "pass": True, "sent": 1})
            host.client.feedback("b.encoder.1", "value", 13)
            assert host.output()["sent_count"] == 3
            records.append({"id": "E-C-7", "pass": True, "sent": 2})
            words = [int(word, 16) for word in host.output()["words"]]
            assert all(
                (word >> 16) & 0xF0 != 0xC0 and not ((word >> 16) & 0xF0 == 0xB0 and 1 <= ((word >> 8) & 127) <= 9)
                for word in words
            )
            records.append(
                {
                    "id": "E-C-8",
                    "pass": True,
                    "sent": 0,
                    "motor_cc": 0,
                    "program_change": 0,
                    "user_observation": "not performed; fake only",
                }
            )
        finally:
            host.close()
        assert not host.ready_file.exists()
        assert host.output()["sent_count"] == 3
        records.append({"id": "E-C-9", "pass": True, "sent": 0})
    result = {
        "scope": "test-only-scripted-midi",
        "physical_device_connected": False,
        "steps": records,
        "pass": len(records),
        "fail": 0,
        "sends": 3,
        "motor_cc": 0,
        "program_change": 0,
        "moves_motors": 0,
    }
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "rehearsal.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def state():
    return json.loads((RUNTIME / "state.json").read_text())


def save(record):
    (RUNTIME / "state.json").write_text(json.dumps(record, indent=2) + "\n")


def client(record):
    credential = (RUNTIME / "token").read_text().strip()
    ready = json.loads((RUNTIME / "ready.json").read_text())
    result = Client(
        ready["url"], credential, ready["surface_control"]["expected"]["instance_id"], accepted_sources=("hardware",)
    )
    result.discover(versions=("1.4",), profiles=("xtouch.compact.standard.hardware",), profile_versions=("1.4",))
    return result


def stop():
    if not (RUNTIME / "state.json").exists():
        return {"stopped": False}
    record = state()
    command = subprocess.run(
        ["/bin/ps", "-p", str(record["pid"]), "-o", "command="], capture_output=True, text=True
    ).stdout
    if str(RUNTIME / "ready.json") not in command:
        raise RuntimeError("Owned process identity not found; refusing to signal unrelated PID")
    os.kill(record["pid"], signal.SIGTERM)
    for _ in range(100):
        if not (RUNTIME / "ready.json").exists():
            return {"stopped": True, "exit_sends": 0}
        time.sleep(0.05)
    raise RuntimeError("Owned process did not stop")


def start(feedback):
    if (RUNTIME / "ready.json").exists():
        stop()
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    token_path = RUNTIME / "token"
    token_path.write_text(secrets.token_hex(32))
    token_path.chmod(0o600)
    args = [
        str(ROOT / ".build/debug/XTouchSurfaceHardware"),
        "--receive-channel",
        "2",
        "--light-protocol",
        "observed114",
        "--token-file",
        str(token_path),
        "--ready-file",
        str(RUNTIME / "ready.json"),
    ]
    if feedback:
        args.append("--allow-surface-feedback")
    environment = dict(os.environ)
    environment.pop("XTOUCH_HARDWARE_TEST_SCRIPT", None)
    environment.pop("XTOUCH_HARDWARE_TEST_REPORT", None)
    with (RUNTIME / "service.log").open("w") as log:
        process = subprocess.Popen(args, stdout=log, stderr=log, env=environment)
    for _ in range(100):
        if (RUNTIME / "ready.json").exists():
            record = {"pid": process.pid, "displays": feedback, "layer": None, "old_epoch": None}
            save(record)
            snapshot = client(record).snapshot()
            assert snapshot["link"]["state"] == "connected" and snapshot["inputs"] == {}
            return {"started": True, "feedback_enabled": feedback, "inputs_unknown": True, "startup_sends": 0}
        if process.poll() is not None:
            raise RuntimeError("Service exited before readiness; inspect isolated log")
        time.sleep(0.05)
    raise RuntimeError("Service did not become ready")


def operate(action, confirmed):
    if action.startswith("start-"):
        return start(action == "start-displays")
    if action == "stop":
        return stop()
    record = state()
    connection = client(record)
    snapshot = connection.snapshot()
    if action == "mark":
        record["old_epoch"] = connection.expected["epoch"]
        save(record)
        return {
            "marked_epoch": connection.expected["epoch"],
            "latest_sequence": snapshot["discovery"]["latest_sequence"],
        }
    if action == "replug":
        assert (
            record["old_epoch"] != connection.expected["epoch"]
            and snapshot["inputs"] == {}
            and snapshot["link"]["state"] == "connected"
        )
        result = connection.call(
            "surface_control_events",
            {"instance_id": connection.instance_id, "epoch": record["old_epoch"], "after_sequence": "0", "limit": 100},
        )
        # SDK call raises stale_epoch; handled below by the CLI as a dedicated operation.
        return result
    if action == "observe":
        values = snapshot["inputs"]
        layers = [
            layer
            for layer in ("a", "b")
            if all(f"{layer}.{kind}.1" in values for kind in ("fader", "touch", "encoder", "button"))
        ]
        assert len(layers) == 1
        record["layer"] = layers[0]
        save(record)
        return {"observed_layer": layers[0], "inputs": values}
    if action in ("button", "ring"):
        # The send gate is an explicit check, never an assert (python -O must not remove it).
        if not confirmed or not record["displays"]:
            raise RuntimeError("Display sends need --confirmed and a start-displays session")
        # Re-observe bank from latest input event; never guess from the starting device state.
        page = connection.call(
            "surface_control_events",
            {
                "instance_id": connection.instance_id,
                "epoch": connection.expected["epoch"],
                "after_sequence": "0",
                "limit": 1000,
            },
        )
        inputs = [row for row in page["events"] if row["kind"] == "input" and row["origin"] == "hardware"]
        assert inputs
        layer = inputs[-1]["control_id"].split(".")[0]
        event = connection.feedback(
            layer + (".button.2" if action == "button" else ".encoder.1"),
            "indicator" if action == "button" else "value",
            "on" if action == "button" else 13,
        )
        return {
            "feedback": event,
            "motor_cc": 0,
            "program_change": 0,
            "note": "transport acceptance is not physical display evidence",
        }
    if action == "check":
        return {
            "snapshot": snapshot,
            "motor_cc": 0,
            "program_change": 0,
            "basis": "typed output vocabulary; user physical observation recorded separately",
        }
    raise ValueError("Unknown action")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "prepare",
            "rehearse",
            "start-readonly",
            "observe",
            "mark",
            "replug",
            "start-displays",
            "button",
            "ring",
            "check",
            "stop",
        ),
    )
    parser.add_argument("--confirmed", action="store_true")
    args = parser.parse_args()
    if args.action == "prepare":
        result = prepare()
    elif args.action == "rehearse":
        result = rehearse()
    elif args.action == "replug":
        from surface_control import SurfaceError

        try:
            operate(args.action, args.confirmed)
            raise AssertionError("Expected stale_epoch for the saved cursor")
        except SurfaceError as error:
            if error.code != "stale_epoch":
                raise
            result = {"old_cursor": "stale_epoch", "inputs_unknown": True, "link": "connected", "sends": 0}
    else:
        result = operate(args.action, args.confirmed)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
