"""Compile the actual audit declarations and prove every Debug mismatch is fatal."""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/XTouchCompactCoreTests/LegacyContextReference.swift"


class ContextShadowGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="xtouch-j3-gate-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        source = SOURCE.read_text()
        if SOURCE.read_bytes() != (ROOT / "Tests/XTouchCompactAppTests/LegacyContextReference.swift").read_bytes():
            raise AssertionError("The two actual test target legacy declarations differ")
        start = source.index("struct LegacyContextComparison:")
        end = source.index("\n/// The self-test compiles exactly the declarations above")
        cls.declarations = source[start:end]
        cls.probe_source = cls.directory / "main.swift"
        cls.probe_source.write_text(
            "import Foundation\n"
            + cls.declarations
            + "\nlet audit = CompactContextAudit()\n"
            + 'let candidate = CommandLine.arguments[1] == "mismatch" ? "other" : "native"\n'
            + 'audit.compare("actual-negative-probe", input: "same-real-operation", native: "native", candidate: candidate)\n'
            + 'print("COMPARE_RETURNED records=\\(audit.comparisons.count)")\n'
        )
        cls.binary = cls.directory / "audit-probe"
        cls.evidence = (
            Path(os.environ["XTOUCH_J3_GATE_PROBE_EVIDENCE_ROOT"])
            if os.environ.get("XTOUCH_J3_GATE_PROBE_EVIDENCE_ROOT")
            else None
        )
        if cls.evidence:
            cls.evidence.mkdir(parents=True, exist_ok=False)
        compile_argv = ["swiftc", "-D", "DEBUG", str(cls.probe_source), "-o", str(cls.binary)]
        compiled = subprocess.run(compile_argv, cwd=cls.directory, capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)
        ast_argv = ["swiftc", "-D", "DEBUG", "-dump-ast", str(cls.probe_source)]
        ast = subprocess.run(ast_argv, cwd=cls.directory, capture_output=True, text=True, timeout=60)
        if ast.returncode:
            raise AssertionError(ast.stdout + ast.stderr)
        cls.metadata = {
            "actual_source": str(SOURCE),
            "actual_source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "source_line_start": source[:start].count("\n") + 1,
            "source_line_end": source[:end].count("\n"),
            "actual_declarations_sha256": hashlib.sha256(cls.declarations.encode()).hexdigest(),
            "probe_source_sha256": hashlib.sha256(cls.probe_source.read_bytes()).hexdigest(),
            "exact_actual_declarations_in_probe": cls.declarations in cls.probe_source.read_text(),
            "compiled_binary_sha256": hashlib.sha256(cls.binary.read_bytes()).hexdigest(),
            "compile_argv": compile_argv,
            "compile_exit": compiled.returncode,
            "ast_argv": ast_argv,
            "ast_exit": ast.returncode,
            "child_cwd": str(cls.directory),
            "runs": [],
        }
        if cls.evidence:
            (cls.evidence / "actual-audit-declarations.swift").write_text(cls.declarations)
            (cls.evidence / "main.swift").write_bytes(cls.probe_source.read_bytes())
            (cls.evidence / "probe.ast.txt").write_text(ast.stdout + ast.stderr)
            shutil.copyfile(cls.binary, cls.evidence / "audit-probe")
            cls.save_metadata()

    @classmethod
    def save_metadata(cls):
        if cls.evidence:
            (cls.evidence / "identity.json").write_text(json.dumps(cls.metadata, indent=2) + "\n")

    def run_probe(self, mode):
        environment = dict(os.environ)
        environment["SWIFT_BACKTRACE"] = "enable=no"
        argv = [str(self.binary), mode]
        result = subprocess.run(argv, cwd=self.directory, env=environment, capture_output=True, text=True, timeout=15)
        self.metadata["runs"].append({"argv": argv, "mode": mode, "exit_code": result.returncode})
        if self.evidence:
            (self.evidence / (mode + ".stdout")).write_text(result.stdout)
            (self.evidence / (mode + ".stderr")).write_text(result.stderr)
            self.save_metadata()
        return result

    def test_actual_equal_comparison_returns_normally(self):
        result = self.run_probe("equal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("COMPARE_RETURNED records=1", result.stdout)

    def test_actual_debug_mismatch_cannot_merely_append_a_record(self):
        result = self.run_probe("mismatch")
        self.assertNotEqual(result.returncode, 0, "A real Debug mismatch returned successfully instead of failing")
        self.assertIn("J3 shadow mismatch", result.stderr)
        self.assertNotIn("COMPARE_RETURNED", result.stdout)
