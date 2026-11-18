from legacy_sdk14 import LegacyPackagingFixture

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

    def test_candidate_provenance_keeps_remote_base_and_local_ahead_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git(root, "init", "-q")
            git(root, "config", "user.name", "t")
            git(root, "config", "user.email", "t@example.invalid")
            (root / "file").write_text("base")
            git(root, "add", "file")
            git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "base")
            base = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/main", base)
            (root / "file").write_text("candidate")
            git(root, "add", "file")
            git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "candidate")
            provenance = package_surface_simulator.source_provenance(root)
            self.assertEqual(
                provenance,
                {
                    "source_origin_main": base,
                    "source_ahead": 1,
                    "source_behind": 0,
                    "delivery_status": "local-unpushed-candidate",
                },
            )
            self.assertNotEqual(provenance["source_origin_main"], git(root, "rev-parse", "HEAD"))

    def test_default_output_for_checkout_matches_its_head(self):
        root = package_surface_simulator.ROOT
        output = package_surface_simulator.default_output()
        self.assertEqual(output.parent, root / "build" / "deliveries")
        self.assertEqual(output.name, "xtouch-surface-simulator-" + git(root, "rev-parse", "--short=7", "HEAD"))


class DeliveryContentTests(unittest.TestCase):
    """The delivery carries shared SDK/schema/fixtures byte for byte from the managed dependency."""

    def setUp(self):
        self.legacy_sdk14 = LegacyPackagingFixture(self)
        shared = package_surface_simulator.SHARED
        if not (shared / package_surface_simulator.SDK_SOURCE).is_file():
            self.skipTest("managed SurfacePlugins dependency is not materialized")
        self.temporary = tempfile.TemporaryDirectory()
        self.stage = Path(self.temporary.name)
        package_surface_simulator.stage_shared_files(self.stage)
        # Stand-in for the binary's `--describe` output, which packaging stages before the manifest.
        described = {
            "contract_version": "1.3",
            "profile": {"id": "xtouch.compact.standard.simulation", "version": "1.3"},
            "expected": {"mapping_revision": "0123456789abcdef"},
        }
        (self.stage / "control-contract.json").write_text(json.dumps({"discovery": described, "tools": []}))
        self.manifest = package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def tearDown(self):
        self.temporary.cleanup()

    def test_shared_files_are_identical_to_the_locked_dependency(self):
        shared = package_surface_simulator.SHARED
        for name, source in package_surface_simulator.SHARED_FILES.items():
            self.assertEqual((self.stage / name).read_bytes(), (shared / source).read_bytes(), name)
        with zipfile.ZipFile(self.stage / "surface-control-sdk-1.4.0.zip") as sdk:
            expected_members = [
                str(Path(source).relative_to("clients/python"))
                for source in package_surface_simulator.sdk_sources(shared)
            ]
            self.assertEqual(sdk.namelist(), expected_members)
            for member, source in zip(expected_members, package_surface_simulator.sdk_sources(shared), strict=True):
                self.assertEqual(sdk.read(member), (shared / source).read_bytes())
            body = sdk.read("surface_control/__init__.py")
        self.assertEqual(body, (shared / package_surface_simulator.SDK_SOURCE).read_bytes())
        self.assertIn(b'__version__ = "1.4.0"', body)
        self.assertNotIn("surface_control_testing/README.md", expected_members)
        with zipfile.ZipFile(self.stage / package_surface_simulator.TEST_SUPPORT_ZIP) as support:
            self.assertIn("surface_control_testing/README.md", support.namelist())
        self.assertIn("surface_control_diagnostics/README.md", expected_members)
        self.assertFalse(
            any(member.startswith("surface_control/surface_control_diagnostics/") for member in expected_members)
        )
        self.assertFalse(
            any(member.startswith("surface_control/surface_control_testing/") for member in expected_members)
        )

    def test_generic_delivery_excludes_integrations_tests_and_host_sdk_copies(self):
        names = {str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file()}
        self.assertFalse(
            any("pipe" in name.lower() or name.startswith(("integrations", "tests")) for name in names), names
        )
        self.assertNotIn("surface-control-sdk-source.json", names)
        self.assertNotIn("surface-control-sdk-1.0.0.zip", names)
        self.assertIn("examples/surface_roundtrip.py", names)
        self.assertEqual(
            (self.stage / "examples/chassis.json").read_bytes(),
            (package_surface_simulator.ROOT / "examples/surface_simulator/chassis.json").read_bytes(),
        )
        self.assertIn("examples/CHASSIS.md", names)

    def test_manifest_records_contract_sdk_revision_and_every_hash(self):
        manifest = self.manifest
        lock = json.loads((package_surface_simulator.ROOT / "configs/surface_plugins.lock.json").read_text())
        self.assertEqual((manifest["surface_control_contract"], manifest["surface_control_sdk"]), ("1.3", "1.4.0"))
        self.assertEqual(manifest["surface_plugins_revision"], lock["revision"])
        # Common fields shared by both hosts (SurfacePlugins docs/surface-control-delivery.md).
        for field in (
            "schema_version",
            "artifact",
            "surface_control_contract",
            "surface_control_sdk",
            "source",
            "source_commit",
            "source_dirty",
            "profile_id",
            "profile_version",
            "mapping_revision",
            "surface_plugins_revision",
            "files_sha256",
            "surface_plugins_files_sha256",
        ):
            self.assertIn(field, manifest)
        self.assertEqual((manifest["schema_version"], manifest["artifact"]), (1, "surface-control-simulator"))
        self.assertEqual((manifest["source"], manifest["source_dirty"]), ("simulation", False))
        self.assertEqual(
            (manifest["profile_id"], manifest["profile_version"], manifest["mapping_revision"]),
            ("xtouch.compact.standard.simulation", "1.3", "0123456789abcdef"),
        )
        self.assertIn("control-contract.json", manifest["files_sha256"])
        self.assertIn("surface-control-sdk-1.4.0.zip", manifest["files_sha256"])
        staged = {str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file()} - {
            "manifest.json"
        }
        self.assertEqual(set(manifest["files_sha256"]), staged)
        for name, digest in manifest["files_sha256"].items():
            self.assertEqual(hashlib.sha256((self.stage / name).read_bytes()).hexdigest(), digest)
        shared = package_surface_simulator.SHARED
        for source, digest in manifest["surface_plugins_files_sha256"].items():
            self.assertEqual(hashlib.sha256((shared / source).read_bytes()).hexdigest(), digest)

    def test_kernel_provenance_records_adopted_contracts_and_keeps_four_fixtures_with_plugins(self):
        manifest = self.manifest
        root = package_surface_simulator.ROOT
        lock = json.loads((root / "configs/control_surface_kit.lock.json").read_text())
        self.assertEqual(manifest["control_surface_kit_revision"], lock["revision"])
        self.assertEqual(
            manifest["control_surface_kit_integration"], "contracts-conformance-binding-connection-and-feedback"
        )
        files = manifest["control_surface_kit_files_sha256"]
        self.assertEqual(
            set(files),
            {
                "Package.swift",
                "LICENSE",
                "Sources/SurfaceDeviceContracts/Boundary.swift",
                "Sources/SurfaceDeviceContracts/Capabilities.swift",
                "Sources/SurfaceDeviceContracts/DeviceContracts.swift",
                "Sources/SurfaceBindingContext/BindingContext.swift",
                "Sources/SurfaceBindingContext/Boundary.swift",
                "Sources/SurfaceBindingContext/ContextResourceIndex.swift",
                "Sources/SurfaceConnectionState/Boundary.swift",
                "Sources/SurfaceConnectionState/ConnectionState.swift",
                "Sources/SurfaceFeedbackPlanning/Boundary.swift",
                "Sources/SurfaceFeedbackPlanning/FeedbackPlan.swift",
                "Sources/SurfaceFeedbackPlanning/FeedbackPreflight.swift",
                "Sources/SurfaceFeedbackPlanning/FeedbackReceipt.swift",
            },
        )
        for path, digest in files.items():
            self.assertEqual(
                hashlib.sha256((root / "build/dependencies/ControlSurfaceKit" / path).read_bytes()).hexdigest(), digest
            )
        for version in ("v1", "v1.1", "v1.2", "v1.3"):
            path = f"fixtures/surface-control-software-{version}.json"
            self.assertIn(path, manifest["surface_plugins_files_sha256"])
            self.assertNotIn(path, files)
        with zipfile.ZipFile(self.stage / package_surface_simulator.SDK_ZIP) as sdk:
            self.assertFalse(
                any("SurfaceDeviceConformance" in member or "ControlSurfaceKit" in member for member in sdk.namelist())
            )

    def test_manifest_follows_the_shared_delivery_convention(self):
        """Field names and rules of SurfacePlugins docs/surface-control-delivery.md at the locked revision."""
        shared = package_surface_simulator.SHARED
        convention = (shared / "docs/surface-control-delivery.md").read_text()
        manifest_section = convention.split("## Unified delivery root and index", 1)[0]
        table = [
            line.split("|")[1].strip().strip("`") for line in manifest_section.splitlines() if line.startswith("| `")
        ]
        self.assertEqual(len(table), 13)
        manifest = self.manifest
        # Every documented common field is present; the rest are documented private fields.
        self.assertLessEqual(set(table), set(manifest))
        self.assertEqual(
            set(manifest) - set(table),
            {
                "product",
                "platform",
                "architecture",
                "configuration",
                "start_protocol",
                "stop_protocol",
                "test_artifacts",
                "source_origin_main",
                "source_ahead",
                "source_behind",
                "delivery_status",
                "control_surface_kit_revision",
                "control_surface_kit_integration",
                "control_surface_kit_files_sha256",
            },
        )
        self.assertIs(type(manifest["schema_version"]), int)
        self.assertIs(manifest["source_dirty"], False)
        self.assertRegex(manifest["source_commit"], r"^[0-9a-f]{40}$")
        self.assertRegex(manifest["surface_plugins_revision"], r"^[0-9a-f]{40}$")
        self.assertRegex(manifest["mapping_revision"], r"^[0-9a-f]{16}$")
        self.assertEqual(
            manifest["test_artifacts"],
            [
                {
                    "artifact": "surface-control-test-only-hardware-double",
                    "qualification": "test-only",
                    "path": package_surface_simulator.TEST_SUPPORT_ZIP,
                }
            ],
        )
        files = manifest["files_sha256"]
        self.assertIn("surface-control-sdk-" + manifest["surface_control_sdk"] + ".zip", files)
        self.assertIn("control-contract.json", files)
        self.assertNotIn("manifest.json", files)
        for name in files:
            self.assertFalse(name.startswith("/") or "\\" in name or ".." in Path(name).parts, name)
        # Every copied shared file is covered, by its path inside the shared package, and identical.
        copied = set(package_surface_simulator.SHARED_FILES.values()) | set(
            [*package_surface_simulator.sdk_sources(shared), *package_surface_simulator.test_support_sources(shared)]
        )
        self.assertEqual(set(manifest["surface_plugins_files_sha256"]), copied)
        for name, source in package_surface_simulator.SHARED_FILES.items():
            self.assertEqual(files[name], manifest["surface_plugins_files_sha256"][source])
        with zipfile.ZipFile(self.stage / "surface-control-sdk-1.4.0.zip") as sdk:
            member = hashlib.sha256(sdk.read("surface_control/__init__.py")).hexdigest()
        self.assertEqual(member, manifest["surface_plugins_files_sha256"][package_surface_simulator.SDK_SOURCE])

    def test_role_map_matches_each_fixture_subset_and_public_default_controls(self):
        role_map = json.loads((self.stage / "conformance-roles.json").read_text())
        self.assertEqual(role_map["schema_version"], 1)
        self.assertEqual(set(role_map), {"schema_version", "fixtures"})
        expected = {
            "input_a": "a.encoder.1",
            "input_b": "a.encoder.2",
            "input_c": "a.encoder.3",
            "input_d": "a.encoder.4",
            "feedback_state": "a.button.1",
            "feedback_progress": "a.encoder.5",
            "feedback_link": "a.button.2",
            "hold_input": "a.touch.1",
            "blocked_input": None,
        }
        fixture_ids = set()
        for name in package_surface_simulator.SHARED_FILES:
            if not name.startswith("surface-control-software-"):
                continue
            fixture = json.loads((self.stage / name).read_text())
            fixture_ids.add(fixture["scenario_id"])
            entry = role_map["fixtures"][fixture["scenario_id"]]
            self.assertEqual(set(entry), {"roles"})
            self.assertEqual(entry["roles"], {role: expected[role] for role in fixture["roles"]})
        self.assertEqual(set(role_map["fixtures"]), fixture_ids)
        self.assertEqual(
            (self.stage / "conformance-roles.json").read_bytes(),
            (package_surface_simulator.ROOT / "examples/surface_simulator/conformance-roles.json").read_bytes(),
        )

    def test_manifest_refuses_a_binary_serving_another_contract_version(self):
        contract = self.stage / "control-contract.json"
        document = json.loads(contract.read_text())
        document["discovery"]["contract_version"] = "1.0"
        contract.write_text(json.dumps(document))
        with self.assertRaises(RuntimeError):
            package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def test_manifest_refuses_sdk_archive_with_old_filename(self):
        (self.stage / "surface-control-sdk-1.4.0.zip").rename(self.stage / "surface-control-sdk-1.3.0.zip")
        with self.assertRaisesRegex(RuntimeError, "SDK archive filename"):
            package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def test_manifest_refuses_wrong_sdk_version_and_modified_source_bytes(self):
        archive = self.stage / "surface-control-sdk-1.4.0.zip"
        original = archive.read_bytes()
        with zipfile.ZipFile(archive) as sdk:
            members = [(entry, sdk.read(entry.filename)) for entry in sdk.infolist()]
        for old_version in (True, False):
            with self.subTest(old_version=old_version):
                with zipfile.ZipFile(archive, "w") as sdk:
                    for entry, body in members:
                        if entry.filename == "surface_control/__init__.py":
                            body = (
                                body.replace(b'__version__ = "1.4.0"', b'__version__ = "1.3.0"')
                                if old_version
                                else body + b"\n# changed SDK source bytes\n"
                            )
                        sdk.writestr(entry, body)
                message = "SDK source version" if old_version else "locked SDK source bytes"
                with self.assertRaisesRegex(RuntimeError, message):
                    package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")
        archive.write_bytes(original)

    def test_sdk_zip_is_reproducible(self):
        with tempfile.TemporaryDirectory() as other:
            package_surface_simulator.stage_shared_files(Path(other))
            self.assertEqual(
                (Path(other) / "surface-control-sdk-1.4.0.zip").read_bytes(),
                (self.stage / "surface-control-sdk-1.4.0.zip").read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()


class CurrentDeliveryContentTests(unittest.TestCase):
    """The delivery carries shared SDK/schema/fixtures byte for byte from the managed dependency."""

    def setUp(self):
        shared = package_surface_simulator.SHARED
        if not (shared / package_surface_simulator.SDK_SOURCE).is_file():
            self.skipTest("managed SurfacePlugins dependency is not materialized")
        self.temporary = tempfile.TemporaryDirectory()
        self.stage = Path(self.temporary.name)
        package_surface_simulator.stage_shared_files(self.stage)
        # Stand-in for the binary's `--describe` output, which packaging stages before the manifest.
        described = {
            "contract_version": "1.3",
            "profile": {"id": "xtouch.compact.standard.simulation", "version": "1.3"},
            "expected": {"mapping_revision": "0123456789abcdef"},
        }
        (self.stage / "control-contract.json").write_text(json.dumps({"discovery": described, "tools": []}))
        self.manifest = package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def tearDown(self):
        self.temporary.cleanup()

    def test_shared_files_are_identical_to_the_locked_dependency(self):
        shared = package_surface_simulator.SHARED
        for name, source in package_surface_simulator.SHARED_FILES.items():
            self.assertEqual((self.stage / name).read_bytes(), (shared / source).read_bytes(), name)
        with zipfile.ZipFile(self.stage / "surface-control-sdk-1.5.0.zip") as sdk:
            expected_members = [
                str(Path(source).relative_to("clients/python"))
                for source in package_surface_simulator.sdk_sources(shared)
            ]
            self.assertEqual(sdk.namelist(), expected_members)
            for member, source in zip(expected_members, package_surface_simulator.sdk_sources(shared), strict=True):
                self.assertEqual(sdk.read(member), (shared / source).read_bytes())
            body = sdk.read("surface_control/__init__.py")
        self.assertEqual(body, (shared / package_surface_simulator.SDK_SOURCE).read_bytes())
        self.assertIn(b'__version__ = "1.5.0"', body)
        self.assertNotIn("surface_control_testing/README.md", expected_members)
        with zipfile.ZipFile(self.stage / package_surface_simulator.TEST_SUPPORT_ZIP) as support:
            self.assertIn("surface_control_testing/README.md", support.namelist())
        self.assertIn("surface_control_diagnostics/README.md", expected_members)
        self.assertFalse(
            any(member.startswith("surface_control/surface_control_diagnostics/") for member in expected_members)
        )
        self.assertFalse(
            any(member.startswith("surface_control/surface_control_testing/") for member in expected_members)
        )

    def test_generic_delivery_excludes_integrations_tests_and_host_sdk_copies(self):
        names = {str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file()}
        self.assertFalse(
            any("pipe" in name.lower() or name.startswith(("integrations", "tests")) for name in names), names
        )
        self.assertNotIn("surface-control-sdk-source.json", names)
        self.assertNotIn("surface-control-sdk-1.0.0.zip", names)
        self.assertIn("examples/surface_roundtrip.py", names)
        self.assertEqual(
            (self.stage / "examples/chassis.json").read_bytes(),
            (package_surface_simulator.ROOT / "examples/surface_simulator/chassis.json").read_bytes(),
        )
        self.assertIn("examples/CHASSIS.md", names)

    def test_manifest_records_contract_sdk_revision_and_every_hash(self):
        manifest = self.manifest
        lock = json.loads((package_surface_simulator.ROOT / "configs/surface_plugins.lock.json").read_text())
        self.assertEqual((manifest["surface_control_contract"], manifest["surface_control_sdk"]), ("1.3", "1.5.0"))
        self.assertEqual(manifest["surface_plugins_revision"], lock["revision"])
        # Common fields shared by both hosts (SurfacePlugins docs/surface-control-delivery.md).
        for field in (
            "schema_version",
            "artifact",
            "surface_control_contract",
            "surface_control_sdk",
            "source",
            "source_commit",
            "source_dirty",
            "profile_id",
            "profile_version",
            "mapping_revision",
            "surface_plugins_revision",
            "files_sha256",
            "surface_plugins_files_sha256",
        ):
            self.assertIn(field, manifest)
        self.assertEqual((manifest["schema_version"], manifest["artifact"]), (1, "surface-control-simulator"))
        self.assertEqual((manifest["source"], manifest["source_dirty"]), ("simulation", False))
        self.assertEqual(
            (manifest["profile_id"], manifest["profile_version"], manifest["mapping_revision"]),
            ("xtouch.compact.standard.simulation", "1.3", "0123456789abcdef"),
        )
        self.assertIn("control-contract.json", manifest["files_sha256"])
        self.assertIn("surface-control-sdk-1.5.0.zip", manifest["files_sha256"])
        staged = {str(path.relative_to(self.stage)) for path in self.stage.rglob("*") if path.is_file()} - {
            "manifest.json"
        }
        self.assertEqual(set(manifest["files_sha256"]), staged)
        for name, digest in manifest["files_sha256"].items():
            self.assertEqual(hashlib.sha256((self.stage / name).read_bytes()).hexdigest(), digest)
        shared = package_surface_simulator.SHARED
        for source, digest in manifest["surface_plugins_files_sha256"].items():
            self.assertEqual(hashlib.sha256((shared / source).read_bytes()).hexdigest(), digest)

    def test_kernel_provenance_records_adopted_contracts_and_keeps_four_fixtures_with_plugins(self):
        manifest = self.manifest
        root = package_surface_simulator.ROOT
        lock = json.loads((root / "configs/control_surface_kit.lock.json").read_text())
        self.assertEqual(manifest["control_surface_kit_revision"], lock["revision"])
        self.assertEqual(
            manifest["control_surface_kit_integration"], "contracts-conformance-binding-connection-and-feedback"
        )
        files = manifest["control_surface_kit_files_sha256"]
        self.assertEqual(
            set(files),
            {
                "Package.swift",
                "LICENSE",
                "Sources/SurfaceDeviceContracts/Boundary.swift",
                "Sources/SurfaceDeviceContracts/Capabilities.swift",
                "Sources/SurfaceDeviceContracts/DeviceContracts.swift",
                "Sources/SurfaceBindingContext/BindingContext.swift",
                "Sources/SurfaceBindingContext/Boundary.swift",
                "Sources/SurfaceBindingContext/ContextResourceIndex.swift",
                "Sources/SurfaceConnectionState/Boundary.swift",
                "Sources/SurfaceConnectionState/ConnectionState.swift",
                "Sources/SurfaceFeedbackPlanning/Boundary.swift",
                "Sources/SurfaceFeedbackPlanning/FeedbackPlan.swift",
                "Sources/SurfaceFeedbackPlanning/FeedbackPreflight.swift",
                "Sources/SurfaceFeedbackPlanning/FeedbackReceipt.swift",
            },
        )
        for path, digest in files.items():
            self.assertEqual(
                hashlib.sha256((root / "build/dependencies/ControlSurfaceKit" / path).read_bytes()).hexdigest(), digest
            )
        for version in ("v1", "v1.1", "v1.2", "v1.3"):
            path = f"fixtures/surface-control-software-{version}.json"
            self.assertIn(path, manifest["surface_plugins_files_sha256"])
            self.assertNotIn(path, files)
        with zipfile.ZipFile(self.stage / package_surface_simulator.SDK_ZIP) as sdk:
            self.assertFalse(
                any("SurfaceDeviceConformance" in member or "ControlSurfaceKit" in member for member in sdk.namelist())
            )

    def test_manifest_follows_the_shared_delivery_convention(self):
        """Field names and rules of SurfacePlugins docs/surface-control-delivery.md at the locked revision."""
        shared = package_surface_simulator.SHARED
        convention = (shared / "docs/surface-control-delivery.md").read_text()
        manifest_section = convention.split("## Unified delivery root and index", 1)[0]
        table = [
            line.split("|")[1].strip().strip("`") for line in manifest_section.splitlines() if line.startswith("| `")
        ]
        self.assertEqual(len(table), 13)
        manifest = self.manifest
        # Every documented common field is present; the rest are documented private fields.
        self.assertLessEqual(set(table), set(manifest))
        self.assertEqual(
            set(manifest) - set(table),
            {
                "product",
                "platform",
                "architecture",
                "configuration",
                "start_protocol",
                "stop_protocol",
                "test_artifacts",
                "source_origin_main",
                "source_ahead",
                "source_behind",
                "delivery_status",
                "control_surface_kit_revision",
                "control_surface_kit_integration",
                "control_surface_kit_files_sha256",
            },
        )
        self.assertIs(type(manifest["schema_version"]), int)
        self.assertIs(manifest["source_dirty"], False)
        self.assertRegex(manifest["source_commit"], r"^[0-9a-f]{40}$")
        self.assertRegex(manifest["surface_plugins_revision"], r"^[0-9a-f]{40}$")
        self.assertRegex(manifest["mapping_revision"], r"^[0-9a-f]{16}$")
        self.assertEqual(
            manifest["test_artifacts"],
            [
                {
                    "artifact": "surface-control-test-only-hardware-double",
                    "qualification": "test-only",
                    "path": package_surface_simulator.TEST_SUPPORT_ZIP,
                }
            ],
        )
        files = manifest["files_sha256"]
        self.assertIn("surface-control-sdk-" + manifest["surface_control_sdk"] + ".zip", files)
        self.assertIn("control-contract.json", files)
        self.assertNotIn("manifest.json", files)
        for name in files:
            self.assertFalse(name.startswith("/") or "\\" in name or ".." in Path(name).parts, name)
        # Every copied shared file is covered, by its path inside the shared package, and identical.
        copied = set(package_surface_simulator.SHARED_FILES.values()) | set(
            [*package_surface_simulator.sdk_sources(shared), *package_surface_simulator.test_support_sources(shared)]
        )
        self.assertEqual(set(manifest["surface_plugins_files_sha256"]), copied)
        for name, source in package_surface_simulator.SHARED_FILES.items():
            self.assertEqual(files[name], manifest["surface_plugins_files_sha256"][source])
        with zipfile.ZipFile(self.stage / "surface-control-sdk-1.5.0.zip") as sdk:
            member = hashlib.sha256(sdk.read("surface_control/__init__.py")).hexdigest()
        self.assertEqual(member, manifest["surface_plugins_files_sha256"][package_surface_simulator.SDK_SOURCE])

    def test_role_map_matches_each_fixture_subset_and_public_default_controls(self):
        role_map = json.loads((self.stage / "conformance-roles.json").read_text())
        self.assertEqual(role_map["schema_version"], 1)
        self.assertEqual(set(role_map), {"schema_version", "fixtures"})
        expected = {
            "input_a": "a.encoder.1",
            "input_b": "a.encoder.2",
            "input_c": "a.encoder.3",
            "input_d": "a.encoder.4",
            "feedback_state": "a.button.1",
            "feedback_progress": "a.encoder.5",
            "feedback_link": "a.button.2",
            "hold_input": "a.touch.1",
            "blocked_input": None,
        }
        fixture_ids = set()
        for name in package_surface_simulator.SHARED_FILES:
            if not name.startswith("surface-control-software-"):
                continue
            fixture = json.loads((self.stage / name).read_text())
            fixture_ids.add(fixture["scenario_id"])
            entry = role_map["fixtures"][fixture["scenario_id"]]
            self.assertEqual(set(entry), {"roles"})
            self.assertEqual(entry["roles"], {role: expected[role] for role in fixture["roles"]})
        self.assertEqual(set(role_map["fixtures"]), fixture_ids)
        self.assertEqual(
            (self.stage / "conformance-roles.json").read_bytes(),
            (package_surface_simulator.ROOT / "examples/surface_simulator/conformance-roles.json").read_bytes(),
        )

    def test_manifest_refuses_a_binary_serving_another_contract_version(self):
        contract = self.stage / "control-contract.json"
        document = json.loads(contract.read_text())
        document["discovery"]["contract_version"] = "1.0"
        contract.write_text(json.dumps(document))
        with self.assertRaises(RuntimeError):
            package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def test_manifest_refuses_sdk_archive_with_old_filename(self):
        (self.stage / "surface-control-sdk-1.5.0.zip").rename(self.stage / "surface-control-sdk-1.3.0.zip")
        with self.assertRaisesRegex(RuntimeError, "SDK archive filename"):
            package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")

    def test_manifest_refuses_wrong_sdk_version_and_modified_source_bytes(self):
        archive = self.stage / "surface-control-sdk-1.5.0.zip"
        original = archive.read_bytes()
        with zipfile.ZipFile(archive) as sdk:
            members = [(entry, sdk.read(entry.filename)) for entry in sdk.infolist()]
        for old_version in (True, False):
            with self.subTest(old_version=old_version):
                with zipfile.ZipFile(archive, "w") as sdk:
                    for entry, body in members:
                        if entry.filename == "surface_control/__init__.py":
                            body = (
                                body.replace(b'__version__ = "1.5.0"', b'__version__ = "1.3.0"')
                                if old_version
                                else body + b"\n# changed SDK source bytes\n"
                            )
                        sdk.writestr(entry, body)
                message = "SDK source version" if old_version else "locked SDK source bytes"
                with self.assertRaisesRegex(RuntimeError, message):
                    package_surface_simulator.write_manifest(self.stage, "0" * 40, "release")
        archive.write_bytes(original)

    def test_sdk_zip_is_reproducible(self):
        with tempfile.TemporaryDirectory() as other:
            package_surface_simulator.stage_shared_files(Path(other))
            self.assertEqual(
                (Path(other) / "surface-control-sdk-1.5.0.zip").read_bytes(),
                (self.stage / "surface-control-sdk-1.5.0.zip").read_bytes(),
            )
