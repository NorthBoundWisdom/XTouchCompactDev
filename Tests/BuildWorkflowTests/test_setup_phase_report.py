"""Exercise explicit diagnostics without changing the default setup contract."""

import io
import json
import subprocess
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from configs import check_host_layers
from configs import setup_local_project as setup


class SetupPhaseReportTests(unittest.TestCase):
    def prepare(self, directory):
        root = Path(directory)
        (root / "configs").mkdir()
        for name in ("surface_plugins", "control_surface_kit"):
            (root / f"configs/{name}.lock.json").write_text(json.dumps({"revision": "a" * 40}))
        return root

    def mocks(self, root, *, validation=0, failure=None):
        calls = []
        stack = ExitStack()
        stack.enter_context(patch.object(setup, "REPO_ROOT", root))
        stack.enter_context(
            patch.object(setup, "ensure_local_build_environment", side_effect=lambda _: calls.append("environment"))
        )
        stack.enter_context(patch.object(setup, "load_app_build_settings", return_value={"example": True}))
        stack.enter_context(
            patch.object(setup, "validate_commands", side_effect=lambda _: calls.append("validate") or validation)
        )
        stack.enter_context(
            patch.object(
                setup,
                "ensure_dependency",
                side_effect=lambda _: calls.append("surface") or (failure() if failure else None),
            )
        )
        stack.enter_context(
            patch.object(setup, "ensure_control_surface_kit", side_effect=lambda _: calls.append("kit"))
        )
        command = stack.enter_context(
            patch.object(setup.subprocess, "run", return_value=subprocess.CompletedProcess([], 0))
        )
        git = stack.enter_context(patch.object(setup, "_git", return_value="a" * 40))
        return stack, calls, command, git

    def test_default_keeps_original_dump_marker_stdout_and_no_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            stack, calls, command, git = self.mocks(root)
            with stack, redirect_stdout(io.StringIO()) as output:
                self.assertEqual(setup.main(), 0)
            self.assertEqual(calls, ["environment", "validate", "surface", "kit"])
            command.assert_called_once_with(
                ["swift", "package", "dump-package"], cwd=root, check=True, stdout=subprocess.DEVNULL
            )
            self.assertEqual(output.getvalue(), "XTouchCompactDev local configuration is ready.\n")
            self.assertEqual(
                json.loads((root / "build/configured.json").read_text()),
                {"schema_version": 1, "app_build": {"example": True}},
            )
            git.assert_not_called()
            self.assertFalse((root / "build/ci-verification").exists())

    def test_explicit_paths_reach_the_actual_shared_scratch_and_artifact_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            stack, calls, command, _ = self.mocks(root)
            with stack:
                self.assertEqual(
                    setup.main(phase_report="build/ci-verification/setup/phase.json", scratch_path="build/swiftpm"), 0
                )
            command.assert_called_once_with(
                [
                    "swift",
                    "package",
                    "--scratch-path",
                    str(root / "build/swiftpm"),
                    "--manifest-cache",
                    "local",
                    "dump-package",
                ],
                cwd=root,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            report = json.loads((root / "build/ci-verification/setup/phase.json").read_text())
            self.assertEqual(report["exit"], 0)
            self.assertEqual(
                [p["name"] for p in report["phases"]],
                [
                    "diagnostic_identity_before",
                    "ensure_local_build_environment",
                    "load_app_build_settings",
                    "validate_commands",
                    "surface_plugins_ensure",
                    "control_surface_kit_ensure",
                    "dump_package",
                    "diagnostic_identity_after",
                ],
            )
            self.assertTrue(all(p["exit"] == 0 and p["seconds"] >= 0 for p in report["phases"]))
            self.assertFalse((root / "build/build").exists())
            self.assertTrue((root / "build/configured.json").is_file())
            self.assertEqual(calls, ["environment", "validate", "surface", "kit"])

    def test_validation_failure_preserves_report_and_never_acquires_or_dumps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            (root / "build").mkdir()
            (root / "build/configured.json").write_text("old")
            stack, calls, command, _ = self.mocks(root, validation=7)
            with stack:
                self.assertEqual(setup.main(phase_report="build/ci/report.json"), 1)
            report = json.loads((root / "build/ci/report.json").read_text())
            self.assertEqual(report["exit"], 1)
            self.assertEqual(report["phases"][-1]["exit"], 7)
            self.assertEqual(calls, ["environment", "validate"])
            self.assertFalse((root / "build/configured.json").exists())
            command.assert_not_called()

    def test_ensure_and_dump_failures_are_visible_with_no_success_marker(self):
        for failed in ("ensure", "dump"):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                root = self.prepare(directory)

                def fail():
                    raise ValueError("failure")

                stack, calls, command, _ = self.mocks(root, failure=fail if failed == "ensure" else None)
                if failed == "dump":
                    command.side_effect = subprocess.CalledProcessError(9, ["swift"])
                with stack, self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    setup.main(phase_report="build/ci/report.json")
                report = json.loads((root / "build/ci/report.json").read_text())
                self.assertEqual(report["exit"], 1)
                self.assertEqual(report["phases"][-1]["exit"], 1)
                self.assertFalse((root / "build/configured.json").exists())
                if failed == "ensure":
                    self.assertNotIn("kit", calls)
                    command.assert_not_called()

    def test_unsafe_dependency_parent_is_rejected_before_any_external_git(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            root = self.prepare(directory)
            (root / "build").mkdir()
            (root / "build/dependencies").symlink_to(external, target_is_directory=True)
            (Path(external) / "sentinel").write_text("unchanged")
            stack, calls, command, git = self.mocks(root)
            with stack, self.assertRaises(ValueError):
                setup.main(phase_report="build/ci/report.json")
            git.assert_not_called()
            command.assert_not_called()
            self.assertEqual(calls, [])
            self.assertEqual((Path(external) / "sentinel").read_text(), "unchanged")
            self.assertFalse((root / "build/configured.json").exists())

    def test_git_metadata_symlink_is_rejected_before_git_can_follow_it(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            root = self.prepare(directory)
            checkout = root / "build/dependencies/SurfacePlugins"
            checkout.mkdir(parents=True)
            (checkout / ".git").symlink_to(external, target_is_directory=True)
            stack, calls, command, git = self.mocks(root)
            with stack, patch("configs.managed_git_dependency._git") as owned_git, self.assertRaises(ValueError):
                setup.main(phase_report="build/ci/report.json")
            owned_git.assert_not_called()
            git.assert_not_called()
            command.assert_not_called()
            self.assertEqual(calls, [])

    def test_report_and_scratch_reject_escape_symlink_or_existing_report(self):
        for report, scratch, symlink in [
            ("build/../outside.json", None, None),
            ("build/ci/report.json", "build/../outside", None),
            ("build/ci/report.json", "build/swiftpm", "swiftpm"),
            ("build/ci/report.json", None, "ci"),
        ]:
            with (
                self.subTest(report=report, scratch=scratch, symlink=symlink),
                tempfile.TemporaryDirectory() as directory,
                tempfile.TemporaryDirectory() as external,
            ):
                root = self.prepare(directory)
                (root / "build").mkdir()
                if symlink:
                    (root / "build" / symlink).symlink_to(external, target_is_directory=True)
                stack, _, command, git = self.mocks(root)
                with stack, self.assertRaises(ValueError):
                    setup.main(phase_report=report, scratch_path=scratch)
                command.assert_not_called()
                git.assert_not_called()
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            (root / "build/ci").mkdir(parents=True)
            existing = root / "build/ci/report.json"
            existing.write_text("previous")
            stack, _, command, _ = self.mocks(root)
            with stack, self.assertRaises(ValueError):
                setup.main(phase_report="build/ci/report.json")
            self.assertEqual(existing.read_text(), "previous")
            command.assert_not_called()

    def test_post_identity_failure_cannot_leave_a_success_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            stack, calls, command, git = self.mocks(root)
            git.side_effect = ["a" * 40, "", ValueError("post-identity failure")]
            with stack, self.assertRaises(ValueError):
                setup.main(phase_report="build/ci/report.json")
            report = json.loads((root / "build/ci/report.json").read_text())
            self.assertEqual(report["exit"], 1)
            self.assertEqual(report["phases"][-1]["name"], "diagnostic_identity_after")
            self.assertEqual(report["phases"][-1]["exit"], 1)
            self.assertEqual(calls, ["environment", "validate", "surface", "kit"])
            command.assert_called_once_with(
                ["swift", "package", "dump-package"], cwd=root, check=True, stdout=subprocess.DEVNULL
            )
            self.assertFalse((root / "build/configured.json").exists())

    def test_report_write_failure_removes_success_marker_and_is_not_silenced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            stack, _, _, _ = self.mocks(root)
            with (
                stack,
                patch.object(setup, "write_phase_report", side_effect=OSError("secret sentinel")),
                self.assertRaises(OSError),
            ):
                setup.main(phase_report="build/ci/report.json")
            self.assertFalse((root / "build/configured.json").exists())

    def test_layer_cli_uses_same_literal_scratch_without_removing_package_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare(directory)
            (root / "configs/host_layers.json").write_text("{}")
            with (
                patch("sys.argv", ["check_host_layers", "--root", str(root), "--scratch-path", "build/swiftpm"]),
                patch.object(check_host_layers.subprocess, "check_output", return_value=b'{"targets":[]}') as command,
                patch.object(check_host_layers, "check_tree", return_value={"errors": [], "edges": []}),
                patch.object(check_host_layers, "check_owned_virtual", return_value=[]),
                self.assertRaises(SystemExit) as outcome,
            ):
                check_host_layers.main()
            self.assertEqual(outcome.exception.code, False)
            command.assert_called_once_with(
                [
                    "swift",
                    "package",
                    "--scratch-path",
                    str(root / "build/swiftpm"),
                    "--manifest-cache",
                    "local",
                    "dump-package",
                ],
                cwd=root,
            )


class NativeManifestPolicyTests(unittest.TestCase):
    def test_bundle_builder_uses_the_same_explicit_local_policy_and_preserves_default(self):
        from configs import macos_workflow as workflow

        for policy in (None, "local"):
            with self.subTest(policy=policy), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / "build/swiftpm/debug/XTouchCompactApp"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"binary")
                with (
                    patch.object(workflow, "REPO_ROOT", root),
                    patch.object(workflow, "BUILD_ROOT", root / "build"),
                    patch.object(workflow, "SWIFTPM_ROOT", root / "build/swiftpm"),
                    patch.object(workflow, "run", side_effect=[None, str(binary.parent)]) as command,
                ):
                    self.assertEqual(workflow.swift_executable("debug", "native", manifest_cache=policy), binary)
                options = ["swift", "build", "--build-path", root / "build/swiftpm", "--configuration", "debug"]
                if policy is not None:
                    options += ["--manifest-cache", "local"]
                self.assertEqual(command.call_args_list[0].args[0], [*options, "--product", "XTouchCompactApp"])
                self.assertEqual(command.call_args_list[1].args[0], [*options, "--show-bin-path"])

    def test_policy_option_cannot_change_release_package_or_other_actions(self):
        from configs import macos_workflow as workflow

        for arguments in (
            ["package", "--manifest-cache", "local"],
            ["build", "--configuration", "release", "--manifest-cache", "local"],
            ["build", "--architecture", "universal", "--manifest-cache", "local"],
        ):
            with (
                self.subTest(arguments=arguments),
                patch.object(workflow, "ensure_dependency") as ensure,
                self.assertRaises(SystemExit) as error,
            ):
                workflow.main(arguments)
            self.assertNotEqual(error.exception.code, 0)
            ensure.assert_not_called()

    def test_ci_compile_link_test_bundle_and_preflight_share_the_explicit_policy(self):
        root = Path(__file__).resolve().parents[2]
        yaml = (root / ".github/workflows/ci.yml").read_text()
        app = yaml.split("  app-macos:", 1)[1]
        run_lines = [line.strip().removeprefix("- ") for line in app.splitlines()]
        commands = [line[5:] for line in run_lines if line.startswith("run: swift ")]
        self.assertEqual(
            commands,
            [
                "swift build --build-path build/swiftpm --build-tests --manifest-cache local",
                "swift build --build-path build/swiftpm --manifest-cache local",
                "swift test --build-path build/swiftpm --skip-build --manifest-cache local",
            ],
        )
        self.assertIn("python3 configs/macos_workflow.py build --manifest-cache local", app)
        self.assertIn(
            "python3 configs/setup_local_project.py --scratch-path build/swiftpm --phase-report build/ci-verification/setup/phase.json",
            app,
        )
        self.assertIn("python3 configs/check_host_layers.py --scratch-path build/swiftpm", yaml)
