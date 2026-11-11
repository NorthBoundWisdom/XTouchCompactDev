"""Exercise configuration failure handling and cleanup boundaries without hardware."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configs import macos_workflow, setup_local_project, source_root_workflow
from configs._vendor.freecm.errors import RepoCommandManifestError
from configs._vendor.freecm.repo_commands import validate_repo_command_manifest, validate_repo_command_manifest_text
from configs.build_environment import ensure_local_build_environment, load_build_environment

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
            payload = {"environment": {"SDK": "$REPO_ROOT/sdk", "LITERAL": "$(touch sentinel)"},
                       "path": ["$REPO_ROOT/tools"]}
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
            with (patch.object(setup_local_project, "REPO_ROOT", root),
                  patch.object(setup_local_project, "ensure_local_build_environment"),
                  patch.object(setup_local_project, "load_app_build_settings", return_value={}),
                  patch.object(setup_local_project, "validate_commands", return_value=1)):
                self.assertEqual(setup_local_project.main(), 1)
            self.assertFalse(marker.exists())

    def test_workflow_propagates_command_failure(self):
        failure = subprocess.CalledProcessError(7, ["swift", "build"])
        with patch.object(macos_workflow.subprocess, "run", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                macos_workflow.run(["swift", "build"])
        self.assertEqual(caught.exception.returncode, 7)

    def test_plugin_initialization_flags(self):
        with patch.object(source_root_workflow, "setup_main", return_value=0) as setup:
            for flag in ("--init", "--initrepo", "--update"):
                self.assertEqual(source_root_workflow.main([flag, "--quiet"]), 0)
            self.assertEqual(setup.call_count, 3)
            self.assertEqual(source_root_workflow.main(["--initlock"]), 0)
            self.assertEqual(setup.call_count, 3)


if __name__ == "__main__":
    unittest.main()
