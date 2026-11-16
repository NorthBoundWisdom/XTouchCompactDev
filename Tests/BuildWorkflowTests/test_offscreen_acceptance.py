"""Permission-free launch/CLI safety checks; never launch a UI or request AX access in CI."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import native_ui, run_offscreen_acceptance

ROOT = Path(__file__).resolve().parents[2]


class OffscreenAcceptanceTests(unittest.TestCase):
    def test_parser_defaults_and_explicit_suite(self):
        args = run_offscreen_acceptance.parse_arguments(
            ["--suite", "offline", "--output", str(ROOT / "build/ui-parser-test")]
        )
        self.assertEqual(args.suite, "offline")
        self.assertIsNone(args.binary)
        with self.assertRaises(SystemExit):
            run_offscreen_acceptance.parse_arguments(["--suite", "unknown"])
        with self.assertRaises(SystemExit):
            run_offscreen_acceptance.parse_arguments(["--output", "/tmp/not-owned-artifacts"])

    def test_missing_permission_is_explicit_and_never_launches_app(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.CompletedProcess([], 77, '{"status":"missing-permission"}', "")
            with (
                patch.object(native_ui, "native_binary", return_value=Path("fake-helper")),
                patch.object(native_ui.subprocess, "run", return_value=result),
            ):
                with self.assertRaises(native_ui.MissingPermission):
                    native_ui.preflight()
            with (
                patch.object(run_offscreen_acceptance.sys, "platform", "darwin"),
                patch.object(run_offscreen_acceptance, "preflight", side_effect=native_ui.MissingPermission("缺权限")),
                patch.object(native_ui.subprocess, "Popen") as launch,
            ):
                self.assertEqual(run_offscreen_acceptance.main(["--output", directory]), 77)
                launch.assert_not_called()
            summary = json.loads((Path(directory) / "summary.json").read_text())
            self.assertEqual(summary["status"], "missing-permission")
            self.assertEqual(summary["results"], [])

    def test_owned_bundle_is_background_before_launch_and_helper_scope_is_enforced(self):
        driver = (ROOT / "tools/native_ui.py").read_text()
        helper = (ROOT / "tools/native_ui.swift").read_text()
        self.assertLess(driver.index('"LSUIElement": True'), driver.index("subprocess.Popen("))
        self.assertIn("not-owned-child", helper)
        self.assertIn("--ui-session-id", helper)
        self.assertIn("AXUIElementCreateApplication(pid)", helper)
        for forbidden in ("CGEvent(", "CGEventPost", "AXUIElementCreateSystemWide", "screencapture", '"osascript"'):
            self.assertNotIn(forbidden, helper + driver)

    def test_desktop_acceptance_scripts_are_not_ci_steps(self):
        for file in (ROOT / ".github/workflows").glob("*.yml"):
            self.assertNotIn("run_offscreen_acceptance.py", file.read_text())
