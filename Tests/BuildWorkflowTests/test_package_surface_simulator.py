"""Delivery naming for the software Surface simulator package (no build is run)."""

import hashlib
import json
import subprocess
import tempfile
import unittest
import zipfile
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


class DeliveryContentTests(unittest.TestCase):
    """The delivery carries shared SDK/schema/fixtures byte for byte from the managed dependency."""

    def setUp(self):
        shared = package_surface_simulator.SHARED
        if not (shared / package_surface_simulator.SDK_SOURCE).is_file():
            self.skipTest("managed SurfacePlugins dependency is not materialized")
        self.temporary = tempfile.TemporaryDirectory()
        self.stage = Path(self.temporary.name)
        package_surface_simulator.stage_shared_files(self.stage)
        self.manifest = package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def tearDown(self):
        self.temporary.cleanup()

    def test_shared_files_are_identical_to_the_locked_dependency(self):
        shared = package_surface_simulator.SHARED
        for name, source in package_surface_simulator.SHARED_FILES.items():
            self.assertEqual((self.stage / name).read_bytes(), (shared / source).read_bytes(), name)
        with zipfile.ZipFile(self.stage / "surface-control-sdk-1.1.0.zip") as sdk:
            self.assertEqual(sdk.namelist(), ["surface_control/__init__.py"])
            body = sdk.read("surface_control/__init__.py")
        self.assertEqual(body, (shared / package_surface_simulator.SDK_SOURCE).read_bytes())
        self.assertIn(b'__version__ = "1.1.0"', body)

    def test_generic_delivery_excludes_integrations_tests_and_host_sdk_copies(self):
        names = {str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file()}
        self.assertFalse(
            any("pipe" in name.lower() or name.startswith(("integrations", "tests")) for name in names), names
        )
        self.assertNotIn("surface-control-sdk-source.json", names)
        self.assertNotIn("surface-control-sdk-1.0.0.zip", names)
        self.assertIn("examples/surface_roundtrip.py", names)

    def test_manifest_records_contract_sdk_revision_and_every_hash(self):
        manifest = self.manifest
        lock = json.loads((package_surface_simulator.ROOT / "configs/surface_plugins.lock.json").read_text())
        self.assertEqual((manifest["surface_control_contract"], manifest["surface_control_sdk"]), ("1.1", "1.1.0"))
        self.assertEqual(manifest["surface_plugins_revision"], lock["revision"])
        staged = {str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file()} - {
            "manifest.json"
        }
        self.assertEqual(set(manifest["files_sha256"]), staged)
        for name, digest in manifest["files_sha256"].items():
            self.assertEqual(hashlib.sha256((self.stage / name).read_bytes()).hexdigest(), digest)
        shared = package_surface_simulator.SHARED
        for source, digest in manifest["surface_plugins_files_sha256"].items():
            self.assertEqual(hashlib.sha256((shared / source).read_bytes()).hexdigest(), digest)

    def test_sdk_zip_is_reproducible(self):
        with tempfile.TemporaryDirectory() as other:
            package_surface_simulator.stage_shared_files(Path(other))
            self.assertEqual(
                (Path(other) / "surface-control-sdk-1.1.0.zip").read_bytes(),
                (self.stage / "surface-control-sdk-1.1.0.zip").read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()
