"""Display tables fail closed when their source profiles or safety claims differ."""

import copy
import unittest
from pathlib import Path

from configs.check_display_targets import render

ROOT = Path(__file__).resolve().parents[2]


def description(source="hardware"):
    return {
        "discovery": {
            "source": source,
            "profile": {
                "id": "test.profile",
                "version": "1",
                "controls": [
                    {
                        "id": "a.encoder.1",
                        "feedback_kinds": ["value"],
                        "range": {"minimum": 0, "maximum": 127},
                        "feedback_range": {"minimum": 0, "maximum": 28, "step": 1},
                    },
                    {"id": "a.button.1", "feedback_kinds": ["indicator"]},
                    {"id": "a.fader.1", "feedback_kinds": []},
                ],
            },
        }
    }


class DisplayTargetTests(unittest.TestCase):
    def test_feedback_range_and_indicator_values_are_generated_from_profile(self):
        table = render(description())
        self.assertIn("0..28; step 1", table)
        self.assertNotIn("0..127", table)
        self.assertIn("off / on / blink", table)
        self.assertIn("physical preset unknown", table)
        changed = copy.deepcopy(description())
        changed["discovery"]["profile"]["controls"][0]["feedback_range"]["maximum"] = 20
        self.assertNotEqual(table, render(changed))

    def test_simulation_inherits_range_and_excludes_all_faders(self):
        value = description("simulation")
        del value["discovery"]["profile"]["controls"][0]["feedback_range"]
        value["discovery"]["profile"]["controls"][2]["feedback_kinds"] = ["value"]
        table = render(value)
        self.assertIn("0..127", table)
        self.assertNotIn("`a.fader.1`", table)
        self.assertIn("simulation only", table)

    def test_hardware_fader_feedback_is_rejected_instead_of_hidden(self):
        value = description()
        value["discovery"]["profile"]["controls"][2]["feedback_kinds"] = ["value"]
        with self.assertRaisesRegex(ValueError, "Hardware faders"):
            render(value)

    def test_unknown_feedback_or_missing_range_cannot_make_a_catalogue(self):
        for kind in ["motor", "value"]:
            with self.subTest(kind=kind):
                value = description()
                value["discovery"]["profile"]["controls"][0] = {"id": "a.encoder.1", "feedback_kinds": [kind]}
                with self.assertRaises(ValueError):
                    render(value)

    def test_style_notes_are_pinned_to_existing_host_implementation(self):
        hardware = (ROOT / "Sources/XTouchCompactCore/CompactHardwareSurface.swift").read_text()
        session = (ROOT / "Sources/XTouchCompactCore/CompactSession.swift").read_text()
        self.assertIn(".ringStyle(encoder: index, style: .single)", hardware)
        self.assertIn("try state.setRing(index, display: .position(Self.ringSegment(for: value)))", session)
