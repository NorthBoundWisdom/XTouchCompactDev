"""Exercise configuration failure handling and cleanup boundaries without hardware."""

import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from configs import macos_workflow, setup_local_project, source_root_workflow
from configs._vendor.freecm.errors import RepoCommandManifestError
from configs._vendor.freecm.repo_commands import (
    validate_repo_command_manifest,
    validate_repo_command_manifest_text,
)
from configs.build_environment import (
    ensure_local_build_environment,
    load_build_environment,
)
from configs.build_paths import build_path
from tools import capture_readme_screenshots

ROOT = Path(__file__).resolve().parents[2]


class WorkflowTests(unittest.TestCase):
    def test_manifest_and_broken_config_reference(self):
        summary = validate_repo_command_manifest(ROOT)
        self.assertEqual(summary.configuration_count, 2)
        manifest = json.loads((ROOT / "configs/freecm.commands.jsonc").read_text())
        manifest["commands"]["run"][0]["configurations"] = ["missing"]
        with self.assertRaises(RepoCommandManifestError):
            validate_repo_command_manifest_text(json.dumps(manifest))

    def test_local_environment_is_preserved_and_expanded_without_shell(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "configs").mkdir()
            (root / "configs/build.local.example.json").write_text('{"environment": {}, "path": []}')
            self.assertTrue(ensure_local_build_environment(root))
            payload = {
                "environment": {"SDK": "$REPO_ROOT/sdk", "LITERAL": "$(touch sentinel)"},
                "path": ["$REPO_ROOT/tools"],
            }
            local = root / "build.local.json"
            local.write_text(json.dumps(payload))
            self.assertFalse(ensure_local_build_environment(root))
            environment = load_build_environment(root, environ={"PATH": "/usr/bin", "SDK": "/old/sdk"})
            self.assertEqual(json.loads(local.read_text()), payload)
            self.assertEqual(environment["SDK"], str(root.resolve() / "sdk"))
            self.assertEqual(environment["PATH"], f"{root.resolve()}/tools:/usr/bin")
            self.assertEqual(environment["LITERAL"], "$(touch sentinel)")

    def test_cleanup_preview_preserves_data_and_unlinks_child_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build = root / "build"
            build.mkdir()
            (build / "configured.json").write_text("{}")
            outside = root / "captures"
            outside.mkdir()
            (outside / "keep").write_text("capture")
            (build / "app").symlink_to(outside, target_is_directory=True)
            (build / "unrelated").write_text("keep")
            with patch.object(source_root_workflow, "REPO_ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                source_root_workflow.clean_build(dry_run=True)
                self.assertTrue((build / "configured.json").exists())
                self.assertTrue((build / "app").is_symlink())
                source_root_workflow.clean_build()
            self.assertFalse((build / "configured.json").exists())
            self.assertFalse((build / "app").is_symlink())
            self.assertEqual((outside / "keep").read_text(), "capture")
            self.assertEqual((build / "unrelated").read_text(), "keep")

    def test_cleanup_rejects_symlinked_build_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "outside").mkdir()
            (root / "build").symlink_to(root / "outside", target_is_directory=True)
            with patch.object(source_root_workflow, "REPO_ROOT", root):
                with self.assertRaises(ValueError):
                    source_root_workflow.clean_build()

    def test_failed_setup_removes_old_success_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "build").mkdir()
            marker = root / "build/configured.json"
            marker.write_text("{}")
            with (
                patch.object(setup_local_project, "REPO_ROOT", root),
                patch.object(setup_local_project, "ensure_local_build_environment"),
                patch.object(setup_local_project, "load_app_build_settings", return_value={}),
                patch.object(setup_local_project, "validate_commands", return_value=1),
            ):
                self.assertEqual(setup_local_project.main(), 1)
            self.assertFalse(marker.exists())

    def test_workflow_propagates_command_failure(self):
        failure = subprocess.CalledProcessError(7, ["swift", "build"])
        with patch.object(macos_workflow.subprocess, "run", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                macos_workflow.run(["swift", "build"])
        self.assertEqual(caught.exception.returncode, 7)

    def test_artifact_writes_reject_symlinked_ancestors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            (root / "build").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                build_path(root, "configured.json")
            (root / "build").unlink()
            (root / "build").mkdir()
            (root / "build/app").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                build_path(root, "app/debug/XTouchCompactApp.app")
            with self.assertRaises(ValueError):
                build_path(root, "../outside")
            self.assertEqual(list(outside.iterdir()), [])

    def test_smoke_requires_structured_false_hardware_marker(self):
        macos_workflow.validate_smoke('log line\n{"type":"xtouch.native_startup","hardwareAccessed":false}')
        for invalid in (
            '{"type":"xtouch.native_startup","hardwareAccessed":"false"}',
            '{"type":"xtouch.native_startup","hardwareAccessed":true}',
            '"hardwareAccessed":false "type":"xtouch.native_startup"',
        ):
            with self.assertRaises(ValueError):
                macos_workflow.validate_smoke(invalid)

    def test_bundle_accepts_swiftpm_lowercase_localization_and_rejects_missing_language(self):
        import plistlib

        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "Test.app"
            executable = bundle / "Contents/MacOS" / macos_workflow.PRODUCT
            executable.parent.mkdir(parents=True)
            executable.write_text("test")
            executable.chmod(0o755)
            (bundle / "Contents/Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": macos_workflow.BUNDLE_ID,
                        "CFBundleExecutable": macos_workflow.PRODUCT,
                        "LSMinimumSystemVersion": "14.0",
                    }
                )
            )
            resources = bundle / "Contents/Resources/XTouchCompactDev_XTouchCompactLocalization.bundle"
            for language in ("en", "zh-hans", "zh-hant"):
                directory = resources / f"{language}.lproj"
                directory.mkdir(parents=True)
                (directory / "Localizable.strings").write_text("test")
            with patch.object(macos_workflow, "run"):
                macos_workflow.verify_bundle(bundle)
                (resources / "zh-hant.lproj/Localizable.strings").unlink()
                with self.assertRaises(ValueError):
                    macos_workflow.verify_bundle(bundle)

    def test_preview_timeout_samples_and_reaps_only_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "preview.png"
            output.write_bytes(b"stale")
            process = MagicMock(pid=123)
            process.wait.side_effect = [subprocess.TimeoutExpired(["preview"], 1), 0]
            with (
                patch.object(capture_readme_screenshots.subprocess, "Popen", return_value=process),
                patch.object(capture_readme_screenshots.subprocess, "run") as sample,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(TimeoutError):
                    capture_readme_screenshots.capture(Path("test-app"), output, "en", timeout=1)
                sample.assert_called_once()
                self.assertEqual(sample.call_args.args[0][:2], ["sample", "123"])
                process.kill.assert_called_once()
                self.assertEqual(process.wait.call_count, 2)
                self.assertFalse(output.exists())

    def test_preview_requires_fresh_png_and_preserves_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "preview.png"
            output.write_bytes(b"stale")
            process = MagicMock()
            process.wait.return_value = 7
            with (
                patch.object(capture_readme_screenshots.subprocess, "Popen", return_value=process),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    capture_readme_screenshots.capture(Path("test-app"), output, "en")
                self.assertEqual(caught.exception.returncode, 7)
            output.write_bytes(b"invalid")
            with self.assertRaises(ValueError):
                capture_readme_screenshots.validate_png(output)

    def test_plugin_initialization_flags(self):
        with patch.object(source_root_workflow, "setup_main", return_value=0) as setup:
            for flag in ("--init", "--initrepo", "--update"):
                self.assertEqual(source_root_workflow.main([flag, "--quiet"]), 0)
            self.assertEqual(setup.call_count, 3)
            self.assertEqual(source_root_workflow.main(["--initlock"]), 0)
            self.assertEqual(setup.call_count, 3)


if __name__ == "__main__":
    unittest.main()
