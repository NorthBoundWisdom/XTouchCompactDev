"""All preflight work must join successfully; tool mutation cannot become a green gate."""

import io
import json
import subprocess
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from configs import ci_preflight_parallel as preflight


class PreflightParallelTests(unittest.TestCase):
    def run_fixture(self, runner, identity=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = io.BytesIO()
            stdout = types.SimpleNamespace(buffer=output, flush=lambda: None)
            with patch.object(preflight.sys, "stdout", stdout):
                code = preflight.run_parallel(
                    root,
                    {"DEVELOPER_DIR": preflight.XCODE},
                    identity_reader=identity or (lambda _: {"swift": "fixed", "git": "fixed", "python": "fixed"}),
                    command_runner=runner,
                )
            directory = root / "build/ci-verification/preflight"
            report = json.loads((directory / "preflight.json").read_text())
            logs = {p.name: p.read_bytes() for p in directory.glob("*.log")}
            return code, report, logs, output.getvalue()

    def test_two_complete_phases_overlap_and_keep_every_original_command_and_log(self):
        barrier = threading.Barrier(2)
        commands = []
        lock = threading.Lock()

        def runner(argv, **kwargs):
            with lock:
                commands.append(argv)
            if argv in [preflight.SETUP, preflight.INSTALL]:
                barrier.wait(timeout=2)
            kwargs["stdout"].write((json.dumps(argv) + "\n").encode())
            self.assertFalse(kwargs["check"])
            self.assertEqual(kwargs["stderr"], subprocess.STDOUT)
            return subprocess.CompletedProcess(argv, 0)

        code, report, logs, output = self.run_fixture(runner)
        self.assertEqual(code, 0)
        self.assertCountEqual(commands, [preflight.SETUP, preflight.INSTALL, preflight.LINT])
        self.assertEqual(
            preflight.SETUP,
            [
                "python3",
                "configs/setup_local_project.py",
                "--scratch-path",
                "build/swiftpm",
                "--phase-report",
                "build/ci-verification/setup/preflight.json",
            ],
        )
        self.assertEqual(preflight.INSTALL, ["brew", "install", "swiftformat", "ruff"])
        self.assertEqual(preflight.LINT, ["python3", "configs/format_repo.py", "--check"])
        self.assertEqual([r["name"] for r in report["commands"]["lint"]], ["install", "lint"])
        self.assertEqual(output, logs["setup.log"] + logs["lint.log"])
        self.assertEqual(report["identity_before"], report["identity_after"])

    def test_setup_failure_cannot_be_hidden_by_successful_lint(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 7 if argv == preflight.SETUP else 0)

        code, report, _, _ = self.run_fixture(runner)
        self.assertEqual(code, 1)
        self.assertEqual(report["commands"]["setup"][0]["exit"], 7)
        self.assertEqual(report["commands"]["lint"][-1]["exit"], 0)

    def test_install_failure_preserves_setup_and_never_claims_lint_ran(self):
        def runner(argv, **kwargs):
            self.assertNotEqual(argv, preflight.LINT)
            return subprocess.CompletedProcess(argv, 9 if argv == preflight.INSTALL else 0)

        code, report, _, _ = self.run_fixture(runner)
        self.assertEqual(code, 1)
        self.assertEqual(report["commands"]["lint"][0]["exit"], 9)
        self.assertEqual(len(report["commands"]["lint"]), 1)
        self.assertEqual(report["commands"]["setup"][0]["exit"], 0)

    def test_lint_failure_is_not_replaced_by_setup_exit(self):
        code, report, _, _ = self.run_fixture(
            lambda argv, **_: subprocess.CompletedProcess(argv, 6 if argv == preflight.LINT else 0)
        )
        self.assertEqual(code, 1)
        self.assertEqual(report["commands"]["lint"][-1]["exit"], 6)

    def test_command_launch_failure_still_joins_the_other_phase(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(argv)
            if argv == preflight.SETUP:
                raise OSError("test launch failure")
            return subprocess.CompletedProcess(argv, 0)

        code, report, _, _ = self.run_fixture(runner)
        self.assertEqual(code, 1)
        self.assertIn(preflight.LINT, calls)
        self.assertEqual(report["commands"]["setup"][0]["error_type"], "OSError")

    def test_tool_path_hash_or_version_change_fails_after_join(self):
        for field in ("selected", "resolved", "sha256", "version"):
            for tool in ("swift", "git", "python3", "xcode_swift"):
                values = [{tool: {field: "before"}}, {tool: {field: "after"}}]
                with self.subTest(tool=tool, field=field):
                    code, report, _, _ = self.run_fixture(
                        lambda argv, **_: subprocess.CompletedProcess(argv, 0), lambda _: values.pop(0)
                    )
                    self.assertEqual(code, 1)
                    self.assertEqual(report["error_type"], "ValueError")
                    self.assertEqual(len(report["commands"]["lint"]), 2)

    def test_fixed_xcode_is_checked_before_starting_any_command(self):
        with self.assertRaisesRegex(ValueError, "fixed Xcode"):
            preflight.tool_identity({"DEVELOPER_DIR": "/other"})

        def identity(_):
            raise ValueError("bad identity")

        code, report, _, _ = self.run_fixture(
            lambda *_args, **_kwargs: self.fail("a command started before identity check"), identity
        )
        self.assertEqual(code, 1)
        self.assertEqual(report["commands"], {})

    def test_actual_identity_reader_binds_resolved_binaries_and_fixed_swift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            developer = root / "Xcode_26.6.app/Contents/Developer"
            swift = developer / "Toolchains/Default/bin/swift"
            swift.parent.mkdir(parents=True)
            paths = {"swift": swift, "git": root / "git", "python3": root / "python3"}
            for name, path in paths.items():
                path.write_text(name + " binary")

            def run(argv, **kwargs):
                value = str(swift) + "\n" if argv[0] == "/usr/bin/xcrun" else "version\n"
                return subprocess.CompletedProcess(argv, 0, value, "")

            with (
                patch.object(preflight, "XCODE", str(developer)),
                patch.object(preflight.shutil, "which", side_effect=lambda name, **_: str(paths[name])),
                patch.object(preflight.subprocess, "run", side_effect=run),
            ):
                first = preflight.tool_identity({"DEVELOPER_DIR": str(developer)})
                paths["git"].write_text("changed binary")
                second = preflight.tool_identity({"DEVELOPER_DIR": str(developer)})
            self.assertNotEqual(first["git"]["sha256"], second["git"]["sha256"])
            self.assertEqual(first["swift"]["resolved"], str(swift.resolve()))
