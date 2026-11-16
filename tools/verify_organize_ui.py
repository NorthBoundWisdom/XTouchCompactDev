"""Production organize controls through AX; links/scenes are explicit setup fixtures."""

from tools.native_ui import OwnedSession


def run(directory, binary):
    results = []
    with OwnedSession(directory / "organize", binary, organize=True) as ui:
        ui.set("inspector.name", "UI Kick")
        assert ui.value("inspector.name") == "UI Kick"
        ui.press("inspector.rename")
        renamed = ui.query()["configuration"]["parameters"][0]["name"] == "UI Kick"
        if renamed:
            assert "UI Kick" in ui.element("surface.fader.1").get("description", "")
            results.append({"case": "Rename", "status": "passed"})
        else:
            results.append(
                {
                    "case": "Rename",
                    "status": "manual-required",
                    "reason": "AX text changes and AXConfirm do not commit the SwiftUI binding in a non-key window; the unchanged model is not a pass.",
                }
            )
        ui.press("inspector.button.2.red")
        assert ui.query()["configuration"]["parameters"][0]["color"] == "red"
        ui.press("fixture.page.organize")
        ui.press("organizeWorkspace.button.Pair")
        assert ui.value("organizeWorkspace.button.Pair") == "highlighted"
        ui.check("inspection.highlight.group", "Pair", "highlight.group")
        ui.press("fixture.page.main")
        ui.set("values.value.surface.fader.1", 50)
        ui.check("inspection.fader2.position", "50", "fader2.position")
        ui.press("fixture.touch2")
        before = len([event for event in ui.query()["motors"] if event["fader"] == 2])
        ui.set("values.value.surface.fader.1", 80)
        ui.check("inspection.fader2.pending", "true", "fader2.pending")
        assert len([event for event in ui.query()["motors"] if event["fader"] == 2]) == before
        ui.press("fixture.release2")
        ui.check("inspection.fader2.position", "80", "fader2.position")
        ui.press("fixture.page.organize")
        scene = ui.query()["scenes"][0]["id"]
        before = len(ui.query()["motors"])
        ui.press("organizeWorkspace.recall." + scene)
        ui.check("inspection.fader.target", "0", "fader.target")
        ui.check("inspection.fader.position", "80", "fader.position")
        assert len(ui.query()["motors"]) == before
        assert ui.element("organizeWorkspace.undo")["enabled"] is True
        ui.press("organizeWorkspace.undo")
        ui.check("inspection.fader.target", "80", "fader.target")
        ui.press("organizeWorkspace.redo")
        ui.check("inspection.fader.target", "0", "fader.target")
        ui.capture("organization-values-history")
        results.append(
            {
                "case": "Color/group highlight, linked touch deferral, non-motor scene recall, undo/redo",
                "status": "passed",
            }
        )
    results.append(
        {
            "case": "Create/edit a link through native leader/member menus",
            "status": "manual-required",
            "reason": "Seeded link behavior is checked; native popup menus are not driven or substituted.",
        }
    )
    return results
