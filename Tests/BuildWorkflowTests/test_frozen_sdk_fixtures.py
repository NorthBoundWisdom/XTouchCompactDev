import hashlib
import json
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests/Fixtures/FrozenSDKs"
EXPECTED = {
    "1.1.0": "1dcc3ce363c7d0b7db4a1c87d0c7827753987164e6c615b3306b00c51bcd7e85",
    "1.2.0": "75edcfcb26560fd18fa6f91277d6a4d2cd6468f18b680a0421416bf8390c1bc1",
}


class FrozenSDKFixtureTests(unittest.TestCase):
    def test_committed_archives_match_original_independent_hashes_and_versions(self):
        provenance = json.loads((FIXTURES / "provenance.json").read_text())
        self.assertEqual(provenance["schemaVersion"], 1)
        self.assertEqual(set(provenance["sdks"]), set(EXPECTED))
        self.assertIn("MIT License", (FIXTURES / "LICENSE").read_text())
        for version, expected in EXPECTED.items():
            with self.subTest(version=version):
                record = provenance["sdks"][version]
                archive = FIXTURES / ("surface-control-sdk-" + version + ".zip")
                self.assertEqual(record["archive"], archive.name)
                self.assertEqual(record["sha256"], expected)
                self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), expected)
                self.assertRegex(record["hostRevision"], r"^[0-9a-f]{40}$")
                self.assertRegex(record["surfacePluginsRevision"], r"^[0-9a-f]{40}$")
                with zipfile.ZipFile(archive) as sdk:
                    self.assertEqual(sdk.namelist(), ["surface_control/__init__.py"])
                    source = sdk.read("surface_control/__init__.py")
                    self.assertIn(('__version__ = "' + version + '"').encode(), source)
                    self.assertEqual(sdk.infolist()[0].date_time, (1980, 1, 1, 0, 0, 0))
