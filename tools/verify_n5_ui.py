"""Native N5 content acceptance. System confirmation/menu routes remain manual."""

from tools.native_ui import OwnedSession


def run(directory, binary):
    results = []
    with OwnedSession(directory / "touch-agent", binary) as ui:
        ui.press("fixture.page.settings")
        assert ui.element("mcp.permission.motorWrites")["enabled"] is False
        ui.press("mcp.permission.parameterWrite")
        assert ui.value("mcp.permission.parameterWrite") == 1
        ui.press("fixture.agent90")
        ui.check("inspection.fader.target", "90", "fader.target")
        ui.check("inspection.fader.position", "0", "fader.position")
        ui.check("inspection.motor.sent", "0", "motor.sent")
        ui.press("fixture.touch")
        ui.press("fixture.agent70")
        ui.check("inspection.fader.pending", "false", "fader.pending")
        ui.press("fixture.release")
        ui.check("inspection.motor.sent", "0", "motor.sent")
        ui.press("mcp.permission.motorWrites")
        ui.press("fixture.touch")
        ui.press("fixture.agent90")
        ui.check("inspection.fader.pending", "true", "fader.pending")
        ui.check("inspection.motor.sent", "0", "motor.sent")
        ui.press("fixture.page.main")
        assert float(ui.value("values.value.surface.fader.1")) == 90
        ui.press("fixture.release")
        ui.check("inspection.fader.position", "90", "fader.position")
        assert len(ui.query()["motors"]) == 1
        ui.capture("touch-release-agent-gates")
        results.append({"case": "N5 touch/release and Agent motor authorization", "status": "passed"})
    with OwnedSession(directory / "layer", binary) as ui:
        ui.press("fixture.physicalB")
        ui.press("fixture.touch")
        ui.press("fixture.release")
        ui.check("inspection.layer.mismatch", "true", "layer.mismatch")
        ui.press("fixture.page.connection")
        assert ui.element("workspace.realignCurrentLayer")["enabled"] is True
        ui.press("workspace.realignCurrentLayer")
        ui.check("inspection.layer.mismatch", "false", "layer.mismatch")
        ui.check("inspection.motor.sent", "0", "motor.sent")
        ui.capture("explicit-realignment")
        results.append({"case": "N5 mismatch and explicit realignment in Mock", "status": "passed"})
    with OwnedSession(directory / "services", binary) as ui:
        ui.press("fixture.page.settings")
        ui.press("mcp.enabled")
        assert ui.value("mcp.enabled") == 1
        ui.check("inspection.mcp.running", "true", "mcp.running")
        ui.press("mcpSettings.copyAccessToken")
        assert ui.value("mcp.tokenCopyStatus") == "Access token copied."
        ui.check("inspection.mcp.copyCount", "1", "mcp.copyCount")
        ui.press("mcp.enabled")
        assert ui.value("mcp.enabled") == 0
        ui.check("inspection.mcp.running", "false", "mcp.running")
        ui.press("mcpSettings.enableOutput")
        assert ui.value("mcpSettings.enableOutput") == 0
        ui.press("fixture.page.main")
        assert "trusted actual" in str(ui.value("notification.osc"))
        ui.check("inspection.osc.enabled", "false", "osc.enabled")
        ui.capture("mcp-copy-osc-refusal")
        results.append(
            {"case": "N5 MCP enable/stop, isolated token action, OSC refusal notification", "status": "passed"}
        )
    persistence = directory / "persistence"
    with OwnedSession(persistence, binary) as ui:
        ui.set("values.value.surface.fader.1", 44)
        assert float(ui.value("values.value.surface.fader.1")) == 44
        ui.press("fixture.flush")
        assert ui.query()["values"]["a.Fader.1"] == 44
        assert (ui.data / "workspace.json").is_file()
    with OwnedSession(persistence, binary) as ui:
        assert float(ui.value("values.value.surface.fader.1")) == 44
        ui.check("inspection.fader.position", "0", "fader.position")
        ui.check("inspection.motor.sent", "0", "motor.sent")
        ui.capture("persisted-target-no-recall")
        results.append({"case": "N5 values survive owned-directory relaunch without motor recall", "status": "passed"})
    results.append(
        {
            "case": "N5 preset menu and native confirmation",
            "status": "manual-required",
            "reason": "Native menu/confirmation routing can require activation; no substitute dialog is used.",
        }
    )
    results.append(
        {
            "case": "N5 OSC ready-stream stop with real trusted feedback",
            "status": "manual-required",
            "reason": "No trusted receiver is configured; only the actual refusal/disabled state is exercised.",
        }
    )
    return results
