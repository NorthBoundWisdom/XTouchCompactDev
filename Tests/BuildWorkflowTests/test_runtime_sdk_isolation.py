from legacy_sdk14 import LegacyPackagingFixture

"""The test hardware double is a separate deliverable, never a runtime SDK member."""

import tempfile
import unittest
import zipfile
from pathlib import Path

from configs import package_surface_hardware, package_surface_simulator


class RuntimeSDKIsolationTests(unittest.TestCase):
    def setUp(self):
        self.legacy_sdk14 = LegacyPackagingFixture(self)

    def test_both_packages_keep_test_double_outside_runtime_sdk(self):
        for package, stage_files in (
            (package_surface_simulator, package_surface_simulator.stage_shared_files),
            (package_surface_hardware, package_surface_hardware.stage_files),
        ):
            with self.subTest(package=package.__name__), tempfile.TemporaryDirectory() as directory:
                stage = Path(directory)
                stage_files(stage)
                with zipfile.ZipFile(stage / "surface-control-sdk-1.4.0.zip") as sdk:
                    self.assertFalse(any(name.startswith("surface_control_testing/") for name in sdk.namelist()))
                    self.assertIn("surface_control/__init__.py", sdk.namelist())
                    self.assertIn("surface_conformance/__main__.py", sdk.namelist())
                with zipfile.ZipFile(stage / "surface-control-test-support-1.4.0.zip") as support:
                    self.assertTrue(all(name.startswith("surface_control_testing/") for name in support.namelist()))
                    self.assertIn("surface_control_testing/README.md", support.namelist())
                    for name in support.namelist():
                        source = package_surface_simulator.SHARED / "clients/python" / name
                        self.assertEqual(support.read(name), source.read_bytes())


class CurrentRuntimeSDKIsolationTests(unittest.TestCase):
    def test_both_packages_keep_test_double_outside_runtime_sdk(self):
        for package, stage_files in (
            (package_surface_simulator, package_surface_simulator.stage_shared_files),
            (package_surface_hardware, package_surface_hardware.stage_files),
        ):
            with self.subTest(package=package.__name__), tempfile.TemporaryDirectory() as directory:
                stage = Path(directory)
                stage_files(stage)
                with zipfile.ZipFile(stage / "surface-control-sdk-1.5.0.zip") as sdk:
                    self.assertFalse(any(name.startswith("surface_control_testing/") for name in sdk.namelist()))
                    self.assertIn("surface_control/__init__.py", sdk.namelist())
                    self.assertIn("surface_conformance/__main__.py", sdk.namelist())
                with zipfile.ZipFile(stage / "surface-control-test-support-1.5.0.zip") as support:
                    self.assertTrue(all(name.startswith("surface_control_testing/") for name in support.namelist()))
                    self.assertIn("surface_control_testing/README.md", support.namelist())
                    for name in support.namelist():
                        source = package_surface_simulator.SHARED / "clients/python" / name
                        self.assertEqual(support.read(name), source.read_bytes())
