"""A generated local demo scope must not expand the shared default mapping allowlist."""

import copy
import json
import unittest
from pathlib import Path

from configs.generate_owned_virtual_mapping import mapping_for

ROOT = Path(__file__).resolve().parents[2]


class OwnedMappingTests(unittest.TestCase):
    def fixture(self):
        template = json.loads(
            (
                ROOT / "build/dependencies/SurfacePlugins/clients/python/surface_panel_demo/mappings/compact.json"
            ).read_text()
        )
        targets = next(p["targets"] for p in template["profiles"] if p["source"] == "hardware")
        controls = [{"id": t["control_id"], "feedback_kinds": [t["kind"]]} for t in targets]
        contract = {
            "owned_virtual_rehearsal": True,
            "physical_evidence": False,
            "discovery": {
                "source": "hardware",
                "contract_version": "1.5",
                "profile": {
                    "id": "xtouch.compact.owned-virtual-rehearsal",
                    "version": "1.5",
                    "capabilities": ["hardware", "session.owned_virtual_rehearsal"],
                    "controls": controls,
                },
            },
        }
        return contract, template

    def test_only_disclosed_owned_profile_gets_exact_unchanged_display_targets(self):
        contract, template = self.fixture()
        before = copy.deepcopy(template)
        result = mapping_for(contract, template)
        old = next(p for p in template["profiles"] if p["source"] == "hardware")
        self.assertEqual(result["profiles"][0]["targets"], old["targets"])
        self.assertEqual(result["profiles"][0]["profile_id"], contract["discovery"]["profile"]["id"])
        self.assertEqual(template, before)
        self.assertNotIn("xtouch.compact.owned-virtual-rehearsal", json.dumps(template))

    def test_missing_marker_wrong_source_and_missing_target_fail_closed(self):
        for mutate in [
            lambda c: c.update(physical_evidence=True),
            lambda c: c.update(owned_virtual_rehearsal=False),
            lambda c: c["discovery"].update(source="simulation"),
            lambda c: c["discovery"]["profile"].update(version="1.4"),
            lambda c: c["discovery"]["profile"].update(controls=[]),
        ]:
            contract, template = self.fixture()
            mutate(contract)
            with self.assertRaises(ValueError):
                mapping_for(contract, template)
