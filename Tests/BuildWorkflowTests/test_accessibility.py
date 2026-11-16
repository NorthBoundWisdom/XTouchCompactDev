"""Static coverage and identity contracts; no native accessibility or desktop access."""

import unittest

from configs.check_accessibility import check, controls


class AccessibilityTests(unittest.TestCase):
    def test_every_primitive_is_identified_and_templates_are_unique(self):
        result = check()
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["duplicates"], [])
        self.assertGreater(result["controls"], 0)

    def test_nested_buttons_and_literal_comments_do_not_hide_missing_ids(self):
        source = """
        // Button("not real") {}
        Menu("Picker(fake)") {
            Button {} label: { Text("TextField(fake)") }
                .accessibilityIdentifier("dialog.confirm")
            Button("Cancel") {}
        }.accessibilityIdentifier("dialog.menu")
        """
        rows = controls(source)
        self.assertEqual([row[0] for row in rows], ["Menu", "Button", "Button"])
        self.assertEqual(["accessibilityIdentifier" in row[3] for row in rows], [True, True, False])

    def test_modifier_closures_do_not_confuse_call_boundaries(self):
        source = """
        TextField("Name", text: binding).accessibilityIdentifier("name").onSubmit { save() }
        Toggle("Enabled", isOn: binding).accessibilityIdentifier("enabled")
        """
        rows = controls(source)
        self.assertEqual(len(rows), 2)
        self.assertTrue(all("accessibilityIdentifier" in row[3] for row in rows))
