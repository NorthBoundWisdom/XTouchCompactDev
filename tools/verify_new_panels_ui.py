"""Library/macro/arm/MCP content checks; native menus and confirmations are kept manual."""

from tools.native_ui import ManualRequired, OwnedSession


def run(directory, binary):
    results = []
    with OwnedSession(directory / "library-mcp", binary, library=True) as ui:
        ui.press("fixture.page.settings")
        assert ui.element("configuration.library.saveConfiguration")["enabled"] is False
        ui.set("configuration.library.configurationName", "UI configuration")
        ui.native("confirm", "configuration.library.configurationName")
        if ui.element("configuration.library.saveConfiguration")["enabled"]:
            ui.press("configuration.library.saveConfiguration")
            ui.check("inspection.library.count", "2", "library.count")
        else:
            results.append(
                {
                    "case": "Library name/save text commit",
                    "status": "manual-required",
                    "reason": "AXSetValue/AXConfirm do not commit a text binding without a key field editor; save remains disabled, not counted as passed.",
                }
            )
        entry = ui.query()["library"][0]["id"]
        assert ui.element("configuration.library.load." + entry)["enabled"] is True
        assert ui.element("configuration.library.delete." + entry)["enabled"] is True
        ui.press("mcp.permission.parameterWrite")
        ui.press("mcp.permission.agentControl")
        ui.press("mcp.permission.simulationControl")
        assert ui.value("mcp.permission.agentControl") == 1
        assert ui.value("mcp.permission.simulationControl") == 1
        ui.press("fixture.agent90")
        ui.press("mcpSettings.recentMcpCalls")
        record = ui.query()["audit"][-1]
        assert ui.value("mcp.call." + record["id"]) == "set_parameter:completed"
        ui.check("inspection.mcp.tasks", "true", "mcp.tasks")
        ui.capture("library-permissions-call-log")
        results.append(
            {"case": "Seeded library request-button availability; MCP permissions/call records", "status": "passed"}
        )
    with OwnedSession(directory / "macro", binary, program=True) as ui:
        ui.press("fixture.page.macros")
        assert ui.element("macros.saveMacro")["enabled"] is False
        try:
            ui.set("macros.macroName", "Created through AX")
            ui.set("macros.parameter", "a.Fader.1")
        except ManualRequired as error:
            results.append(
                {"case": "Macro creation parameter selection", "status": "manual-required", "reason": str(error)}
            )
        else:
            ui.set("macros.value", "20")
            ui.press("macros.addStep")
            ui.press("macros.saveMacro")
            assert int(ui.query()["summary"]["macros.count"]) == 2
            results.append({"case": "Macro creation", "status": "passed"})
        ui.press("fixture.touch")
        ui.press("macros.runMacro.ui-macro")
        assert ui.value("macros.result.1") == "deferred"
        assert ui.value("macros.result.2") == "deferred"
        ui.check("inspection.motor.sent", "0", "motor.sent")
        assert ui.query()["summary"]["macro.results"] == "deferred,deferred"
        ui.capture("macro-step-results")
        results.append({"case": "Macro run outcomes through production buttons and touch gate", "status": "passed"})
    for example in [False, True]:
        with OwnedSession(directory / ("arm-pose" if example else "arm-empty"), binary, example=example) as ui:
            before = ui.query()["values"]
            ui.press("fixture.page.arm")
            ui.press("workspace.panel.armPreview")
            assert ui.value("workspace.panel.armPreview") == 1
            ui.check("inspection.arm.pose", str(example).lower(), "arm.pose")
            if example:
                assert "J1" in str(ui.value("arm.joint.1"))
            else:
                assert "parameters" in str(ui.value("arm.empty"))
            assert ui.query()["values"] == before
            ui.check("inspection.motor.sent", "0", "motor.sent")
            ui.capture("arm-content")
            results.append(
                {
                    "case": "Arm preview " + ("pose" if example else "empty state") + " and content visibility toggle",
                    "status": "passed",
                }
            )
    results.extend(
        [
            {
                "case": "Full Parameters workspace AX navigation",
                "status": "manual-required",
                "reason": "AX returns CannotComplete while constructing the full editor; the actual macro content is hosted separately, not counted as full workspace navigation.",
            },
            {
                "case": "Library load/delete native confirmation buttons",
                "status": "manual-required",
                "reason": "Native confirmation dialogs are not replaced by a test panel and are not opened offscreen.",
            },
            {
                "case": "Panels menu-bar routing",
                "status": "manual-required",
                "reason": "The real PanelMenu content is checked in a non-key carrier; menu-bar activation/routing is not driven.",
            },
        ]
    )
    return results
