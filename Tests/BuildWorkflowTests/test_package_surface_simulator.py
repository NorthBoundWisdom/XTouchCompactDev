"""Delivery naming for the software Surface simulator package (no build is run)."""

import subprocess
import tempfile
import unittest
from pathlib import Path

from configs import package_surface_simulator


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


class DeliveryNamingTests(unittest.TestCase):
    def test_default_output_uses_this_repository_head_short_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git(root, "init", "-q")
            (root / "file").write_text("x")
            git(root, "add", "file")
            git(
                root,
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "-m",
                "init",
            )
            short = git(root, "rev-parse", "--short=7", "HEAD")
            output = package_surface_simulator.default_output(root)
            self.assertEqual(output, root / "build" / "deliveries" / ("xtouch-surface-simulator-" + short))

    def test_default_output_for_checkout_matches_its_head(self):
        root = package_surface_simulator.ROOT
        output = package_surface_simulator.default_output()
        self.assertEqual(output.parent, root / "build" / "deliveries")
        self.assertEqual(output.name, "xtouch-surface-simulator-" + git(root, "rev-parse", "--short=7", "HEAD"))


if __name__ == "__main__":
    unittest.main()
