"""Universal assembly and final-package provenance, with all subprocesses isolated or fake."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from configs import macos_workflow as workflow


class AppPackageTests(unittest.TestCase):
    def test_architecture_selection_is_explicit(self):
        with patch.object(workflow.platform, "machine", return_value="arm64"):
            self.assertEqual(workflow.architectures("native"), ("arm64",))
        self.assertEqual(workflow.architectures("universal"), ("arm64", "x86_64"))
        self.assertEqual(workflow.architectures("x86_64"), ("x86_64",))
        with self.assertRaises(ValueError):
            workflow.architectures("ppc")

    def test_universal_build_uses_two_isolated_triples_lipo_and_localization(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build = root / "build"
            calls = []

            def run(command, **kwargs):
                command = [str(item) for item in command]
                calls.append(command)
                if "--show-bin-path" in command:
                    path = Path(command[command.index("--build-path") + 1]) / "release"
                    path.mkdir(parents=True, exist_ok=True)
                    (path / workflow.PRODUCT).write_bytes(b"fake")
                    resources = path / "XTouchCompactDev_XTouchCompactLocalization.bundle"
                    resources.mkdir(exist_ok=True)
                    (resources / "resource").write_bytes(b"locale")
                    return str(path)
                if command[0] == "lipo":
                    Path(command[-1]).write_bytes(b"fat")
                return ""

            with (
                patch.object(workflow, "REPO_ROOT", root),
                patch.object(workflow, "BUILD_ROOT", build),
                patch.object(workflow, "SWIFTPM_ROOT", build / "swiftpm"),
                patch.object(workflow, "run", side_effect=run),
            ):
                result = workflow.swift_executable("release", "universal")
                self.assertEqual(result.read_bytes(), b"fat")
                self.assertEqual(
                    (result.parent / "XTouchCompactDev_XTouchCompactLocalization.bundle/resource").read_bytes(),
                    b"locale",
                )
                triples = {call[call.index("--triple") + 1] for call in calls if "--product" in call}
                self.assertEqual(triples, {"arm64-apple-macosx14.0", "x86_64-apple-macosx14.0"})
                self.assertEqual(len([call for call in calls if call[0] == "lipo"]), 1)

    def test_prebuilt_slices_require_exact_source_dependency_hashes_and_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "configs").mkdir()
            (root / "configs/surface_plugins.lock.json").write_text(json.dumps({"revision": "b" * 40}))
            folder = root / "build/native-slices/arm64"
            folder.mkdir(parents=True)
            (folder / workflow.PRODUCT).write_bytes(b"slice")
            (folder / "XTouchCompactDev_XTouchCompactLocalization.bundle").mkdir()
            with (
                patch.object(workflow, "REPO_ROOT", root),
                patch.object(workflow, "BUILD_ROOT", root / "build"),
                patch.object(
                    workflow,
                    "source_metadata",
                    return_value={"XTouchSourceRevision": "a" * 40, "XTouchSourceTreeDirty": False},
                ),
                patch.object(workflow, "run", return_value="arm64") as command,
            ):
                proof = {**workflow.slice_identity("arm64"), "files_sha256": workflow.slice_hashes(folder)}
                record = folder / "slice.json"
                record.write_text(json.dumps(proof))
                self.assertEqual(workflow.verify_release_slice(folder.parent, "arm64"), folder / workflow.PRODUCT)
                for field, wrong in (
                    ("commit", "c" * 40),
                    ("surface_plugins_revision", "c" * 40),
                    ("architecture", "x86_64"),
                    ("configuration", "debug"),
                ):
                    record.write_text(json.dumps({**proof, field: wrong}))
                    with self.assertRaises(ValueError, msg=field):
                        workflow.verify_release_slice(folder.parent, "arm64")
                record.write_text(json.dumps(proof))
                command.return_value = "x86_64"
                with self.assertRaises(ValueError):
                    workflow.verify_release_slice(folder.parent, "arm64")
                command.return_value = "arm64"
                (folder / workflow.PRODUCT).write_bytes(b"tampered")
                with self.assertRaises(ValueError):
                    workflow.verify_release_slice(folder.parent, "arm64")
                with self.assertRaises(ValueError):
                    workflow.swift_executable("debug", "universal", folder.parent)

    def test_parallel_package_waits_for_both_slice_artifacts_and_preserves_all_smokes(self):
        text = (workflow.REPO_ROOT / ".github/workflows/package.yml").read_text()
        self.assertIn("arch: [arm64, x86_64]", text)
        self.assertIn("needs: package-macos", text)
        self.assertIn("--prebuilt-slices build/native-slices", text)
        self.assertLess(text.index("Save compiled release slice"), text.index("Stage exact-commit slice"))
        self.assertIn("os: [macos-26, macos-15-intel]", text)
        self.assertIn("if len(assets) != 2:", text)

    def test_release_payload_rejects_each_debug_acceptance_identifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "app"
            binary.write_bytes(b"release payload")
            workflow.verify_release_test_hooks(binary)
            for marker in workflow.RELEASE_FORBIDDEN_HOOKS:
                binary.write_bytes(b"MachO-prefix" + marker.encode() + b"suffix")
                with self.assertRaisesRegex(ValueError, "Debug acceptance hooks"):
                    workflow.verify_release_test_hooks(binary)

    def test_build_records_pin_source_dependency_architectures_and_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "configs").mkdir()
            lock = "b" * 40
            (root / "configs/surface_plugins.lock.json").write_text(json.dumps({"revision": lock}))
            asset = root / "build/package/test.zip"
            asset.parent.mkdir(parents=True)
            asset.write_bytes(b"asset")
            asset.with_suffix(".zip.sha256").write_text(f"{workflow.sha256(asset)}  {asset.name}\n")
            with (
                patch.object(workflow, "REPO_ROOT", root),
                patch.object(workflow, "BUILD_ROOT", root / "build"),
                patch.object(
                    workflow, "load_app_build_settings", return_value={"MARKETING_VERSION": "1.2.3", "ARCHIVE_ID": "5"}
                ),
                patch.object(
                    workflow,
                    "source_metadata",
                    return_value={"XTouchSourceRevision": "a" * 40, "XTouchSourceTreeDirty": False},
                ),
                patch.object(workflow, "run", return_value="Swift 6.2"),
            ):
                workflow.write_build_records([asset], "universal")
            proof = workflow.validate_package_record(
                asset, expected_commit="a" * 40, expected_plugins_revision=lock, require_clean=True
            )
            self.assertEqual(proof["architectures"], ["arm64", "x86_64"])
            self.assertIs(proof["notarized"], False)
            path = asset.with_suffix(".zip.build.json")
            for key, value in (
                ("dirty", 1),
                ("sha256", "0" * 64),
                ("architecture", []),
                ("schema_version", True),
                ("signature", "developer-id"),
                ("architectures", ["arm64"]),
                ("surface_plugins_revision", "invalid"),
            ):
                invalid = {**proof, key: value}
                path.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError, msg=key):
                    workflow.validate_package_record(asset)
            path.write_text(json.dumps({**proof, "dirty": True}))
            with self.assertRaises(ValueError):
                workflow.validate_package_record(asset, require_clean=True)
            path.write_text(json.dumps(proof))
            with self.assertRaises(ValueError):
                workflow.validate_package_record(asset, expected_commit="c" * 40)
            with self.assertRaises(ValueError):
                workflow.validate_package_record(asset, expected_plugins_revision="c" * 40)
            asset.write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                workflow.validate_package_record(asset)

    def test_dmg_always_detaches_when_payload_validation_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "build").mkdir()
            calls = []
            with (
                patch.object(workflow, "REPO_ROOT", root),
                patch.object(workflow, "BUILD_ROOT", root / "build"),
                patch.object(workflow, "validate_package_record", return_value={}),
                patch.object(workflow, "run", side_effect=lambda argv, **kwargs: calls.append(argv)),
                patch.object(workflow, "verify_packaged_payload", side_effect=ValueError("mismatch")),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(ValueError):
                    workflow.check_package(root / "test.dmg")
            self.assertEqual(calls[0][:3], ["hdiutil", "attach", (root / "test.dmg").resolve()])
            self.assertIn("-readonly", calls[0])
            self.assertIn("-nobrowse", calls[0])
            self.assertEqual(calls[-1][:2], ["hdiutil", "detach"])

    def test_package_workflow_requires_both_native_runners_and_clean_exact_commit(self):
        text = (workflow.REPO_ROOT / ".github/workflows/package.yml").read_text()
        for marker in (
            "workflow_dispatch:",
            "tags: ['v*']",
            "package --architecture universal",
            "macos-26",
            "macos-15-intel",
            "needs: package-macos",
            "GITHUB_SHA",
            "expected_plugins_revision",
            "require_clean=True",
        ):
            self.assertIn(marker, text)

    def test_final_payload_smoke_requires_explicit_no_window_evidence(self):
        valid = '{"type":"xtouch.native_startup","mode":"headless","hardwareAccessed":false,"windowCreated":false,"firstFramePresented":false}'
        workflow.validate_smoke(valid, mode="headless")
        for marker in (
            '{"type":"xtouch.native_startup","hardwareAccessed":false}',
            '{"type":"xtouch.native_startup","hardwareAccessed":false,"windowCreated":true}',
        ):
            with self.assertRaises(ValueError):
                workflow.validate_smoke(marker, mode="headless")

    def test_gui_and_headless_smoke_cannot_impersonate_each_other(self):
        for mode in ("gui", "headless"):
            marker = {
                "type": "xtouch.native_startup",
                "mode": mode,
                "hardwareAccessed": False,
                "windowCreated": mode == "gui",
                "firstFramePresented": mode == "gui",
            }
            workflow.validate_smoke(json.dumps(marker), mode=mode)
            with self.assertRaises(ValueError):
                workflow.validate_smoke(json.dumps(marker), mode="headless" if mode == "gui" else "gui")
            for field in ("windowCreated", "firstFramePresented"):
                with self.assertRaises(ValueError):
                    workflow.validate_smoke(json.dumps({**marker, field: not marker[field]}), mode=mode)

    def test_final_package_runs_both_startup_levels(self):
        import plistlib

        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "Test.app"
            contents = bundle / "Contents"
            contents.mkdir(parents=True)
            proof = {
                "version": "1.2.3",
                "build": "5",
                "commit": "a" * 40,
                "dirty": False,
                "architectures": ["arm64", "x86_64"],
            }
            (contents / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleShortVersionString": "1.2.3",
                        "CFBundleVersion": "5",
                        "XTouchSourceRevision": "a" * 40,
                        "XTouchSourceTreeDirty": False,
                    }
                )
            )
            (contents / "MacOS").mkdir()
            (contents / "MacOS" / workflow.PRODUCT).write_bytes(b"release executable")
            calls = []

            def run(argv, **kwargs):
                calls.append(argv)
                if argv[0] == "lipo":
                    return "arm64 x86_64"
                gui = argv[-1] == "--startup-smoke"
                return json.dumps(
                    {
                        "type": "xtouch.native_startup",
                        "mode": "gui" if gui else "headless",
                        "hardwareAccessed": False,
                        "windowCreated": gui,
                        "firstFramePresented": gui,
                    }
                )

            with (
                patch.object(workflow, "verify_bundle"),
                patch.object(workflow, "run", side_effect=run),
                patch.object(workflow.platform, "machine", return_value="arm64"),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                workflow.verify_packaged_payload(bundle, proof)
            self.assertEqual([call[-1] for call in calls[1:]], ["--startup-smoke=headless", "--startup-smoke"])
