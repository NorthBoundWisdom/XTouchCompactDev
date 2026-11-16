"""The opt-in example and its data run from either runtime archive without checkout imports."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from configs import package_surface_hardware, package_surface_simulator


class PanelDemoPackagingTests(unittest.TestCase):
    def test_both_sdk_archives_preserve_all_demo_sources_and_json_resources(self):
        shared = package_surface_simulator.SHARED
        expected = {
            str(path.relative_to(shared / "clients/python")): path.read_bytes()
            for path in (shared / "clients/python/surface_panel_demo").rglob("*")
            if path.is_file() and path.suffix in (".py", ".md", ".json")
        }
        self.assertIn("surface_panel_demo/reference_actual.json", expected)
        self.assertIn("surface_panel_demo/mappings/compact.json", expected)
        for package, stage_files in [
            (package_surface_simulator, package_surface_simulator.stage_shared_files),
            (package_surface_hardware, package_surface_hardware.stage_files),
        ]:
            with self.subTest(package=package.__name__), tempfile.TemporaryDirectory() as directory:
                stage = Path(directory)
                stage_files(stage)
                with zipfile.ZipFile(stage / "surface-control-sdk-1.4.0.zip") as sdk:
                    actual = {name: sdk.read(name) for name in sdk.namelist() if name.startswith("surface_panel_demo/")}
                    self.assertEqual(actual, expected)
                self.assertEqual(
                    (stage / "status-panel-demo.md").read_bytes(), (shared / "docs/status-panel-demo.md").read_bytes()
                )

    def test_reference_source_and_compact_mapping_load_from_zip_outside_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            package_surface_simulator.stage_shared_files(stage)
            script = (
                "import json; from surface_panel_demo import ReferenceSource,load_mapping; "
                'print(json.dumps({"sample":ReferenceSource().sample(0),"mapping":load_mapping("compact")}))'
            )
            result = subprocess.run(
                [sys.executable, "-B", "-c", script],
                cwd=stage,
                text=True,
                capture_output=True,
                check=True,
                env={**os.environ, "PYTHONPATH": str(stage / "surface-control-sdk-1.4.0.zip")},
            )
            value = json.loads(result.stdout)
            self.assertEqual(value["sample"]["published_at"], 0)
            self.assertTrue(value["sample"]["values"]["fresh"])
            self.assertEqual(len(value["mapping"]["profiles"]), 2)
