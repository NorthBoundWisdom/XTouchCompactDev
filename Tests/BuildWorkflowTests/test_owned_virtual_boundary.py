"""The owned backend cannot gain global discovery or an unbounded asynchronous hop."""

import tempfile
import unittest
from pathlib import Path

from configs.check_host_layers import OWNED_FILES, OWNED_FORBIDDEN, check_owned_virtual

ROOT = Path(__file__).resolve().parents[2]


class OwnedBoundaryTests(unittest.TestCase):
    def test_actual_owned_sources_have_no_forbidden_global_or_async_path(self):
        self.assertEqual(check_owned_virtual(ROOT), [])

    def test_each_real_forbidden_api_and_async_hop_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in OWNED_FILES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("import Foundation\nstruct Boundary {}\n")
            target = root / OWNED_FILES[0]
            for name in sorted(OWNED_FORBIDDEN):
                with self.subTest(api=name):
                    target.write_text("func invalid() { " + name + "() }\n")
                    self.assertTrue(any(name in error for error in check_owned_virtual(root)))
            for code in [
                "Task { work() }",
                "Task.detached { work() }",
                "queue.async { work() }",
                "queue.asyncAfter(deadline: now) { work() }",
            ]:
                with self.subTest(code=code):
                    target.write_text("func invalid() { " + code + " }\n")
                    self.assertTrue(any("asynchronous" in error for error in check_owned_virtual(root)))
            target.write_text('// MIDIGetSource() in documentation is not a call\nlet text = "Task { }"\n')
            self.assertEqual(check_owned_virtual(root), [])
