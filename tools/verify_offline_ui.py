"""Read-only fixture import and native replay controls; file panel routing remains manual."""

import hashlib

from tools.native_ui import ROOT, OwnedSession


def run(directory, binary):
    results = []
    for fixture, assessment in [
        ("xtouch-sample.jsonl", "no-recorded-violations"),
        ("xtouch-incomplete.jsonl", "inconclusive"),
        ("bcr-sample.jsonl", "not-applicable"),
    ]:
        source = ROOT / "Tests/Fixtures/Capture" / ("xtouch-sample.jsonl" if "xtouch-" in fixture else fixture)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        with OwnedSession(directory / fixture.removesuffix(".jsonl"), binary, fixture=fixture) as ui:
            before = ui.query()["values"]
            ui.press("fixture.page.offline")
            ui.check("inspection.offline.audit", assessment, "offline.audit")
            if fixture == "xtouch-sample.jsonl":
                assert ui.element("offlineCaptureView.stepReplay")["enabled"] is True
                ui.press("offlineCaptureView.stepReplay")
                ui.check("inspection.offline.cursor", "1", "offline.cursor")
                ui.set("offlineCaptureView.slider.1", 100)
                ui.check("inspection.offline.position", "0", "offline.position")
                ui.press("offlineCaptureView.stepReplay")
                ui.press("offlineCaptureView.runToEnd")
                ui.check("inspection.offline.cursor", "14", "offline.cursor")
                ui.press("offlineCaptureView.resetReplay")
                ui.check("inspection.offline.cursor", "0", "offline.cursor")
            elif fixture == "bcr-sample.jsonl":
                assert ui.native("inspect", "offlineCaptureView.stepReplay")["status"] == "identifier-absent"
                assert ui.query()["summary"]["offline.device"] == "BCR2000"
            assert ui.query()["values"] == before
            ui.check("inspection.motor.sent", "0", "motor.sent")
            ui.capture("offline-" + assessment)
            assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
            results.append({"case": "Read-only import/view: " + fixture, "status": "passed"})
    with OwnedSession(directory / "pause", binary, fixture="xtouch-long.jsonl") as ui:
        ui.press("fixture.page.offline")
        ui.press("offlineCaptureView.runToEnd")
        assert ui.element("offlineCaptureView.pauseReplay")["enabled"] is True
        ui.press("offlineCaptureView.pauseReplay")
        ui.check("inspection.offline.playing", "false", "offline.playing")
        ui.press("offlineCaptureView.resetReplay")
        ui.press("fixture.advance")
        ui.check("inspection.offline.cursor", "0", "offline.cursor")
        ui.check("inspection.fader.target", "0", "fader.target")
        ui.capture("pause-reset-isolated-replay")
        results.append(
            {
                "case": "Run/pause/reset under injected replay scheduling; main console remains distinct",
                "status": "passed",
            }
        )
    results.append(
        {
            "case": "System native Open capture file panel",
            "status": "manual-required",
            "reason": "Import uses immutable fixture bytes at isolated startup; the native file picker is not opened.",
        }
    )
    return results
