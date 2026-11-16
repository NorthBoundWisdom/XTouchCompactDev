"""Package-local checkers accept only authenticated legacy1.4/current1.5 metadata."""

import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from configs.surface_sdk_metadata import package_sdk, source_version


class SDKMetadataTests(unittest.TestCase):
    def package(self, directory, version, source=None):
        directory = Path(directory)
        archive = directory / ("surface-control-sdk-" + version + ".zip")
        with zipfile.ZipFile(archive, "w") as payload:
            payload.writestr("surface_control/__init__.py", source or ('__version__ = "' + version + '"'))
        manifest = {
            "surface_control_sdk": version,
            "files_sha256": {archive.name: hashlib.sha256(archive.read_bytes()).hexdigest()},
        }
        (directory / "manifest.json").write_text(json.dumps(manifest))
        return archive, manifest

    def test_exact_legacy_and_current_versions_are_supported(self):
        for version in ["1.4.0", "1.5.0"]:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                archive, _ = self.package(directory, version)
                self.assertEqual(package_sdk(directory), (archive, version))

    def test_unknown_or_ambiguous_module_versions_are_rejected(self):
        for source in ['__version__ = "1.6.0"', '__version__ = "1.4.0"\n__version__ = "1.5.0"', 'version = "1.5.0"']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                source_version(source)
        with tempfile.TemporaryDirectory() as directory:
            self.package(directory, "1.6.0")
            with self.assertRaisesRegex(ValueError, "Unsupported delivery"):
                package_sdk(directory)

    def test_embedded_source_version_must_match_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            self.package(directory, "1.5.0", '__version__ = "1.4.0"')
            with self.assertRaisesRegex(ValueError, "module version"):
                package_sdk(directory)

    def test_changed_zip_hash_missing_file_and_multiple_archives_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, _ = self.package(directory, "1.5.0")
            archive.write_bytes(archive.read_bytes() + b"tampered")
            with self.assertRaisesRegex(ValueError, "hash"):
                package_sdk(directory)
            archive.unlink()
            with self.assertRaisesRegex(ValueError, "name"):
                package_sdk(directory)
        with tempfile.TemporaryDirectory() as directory:
            self.package(directory, "1.5.0")
            (Path(directory) / "surface-control-sdk-1.4.0.zip").write_bytes(b"extra")
            with self.assertRaisesRegex(ValueError, "name"):
                package_sdk(directory)
