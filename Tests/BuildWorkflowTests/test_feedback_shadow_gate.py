"""Compile the exact actual J4 comparison/checker declarations, not a replacement checker."""

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/XTouchCompactCore/CompactFeedbackRuntime.swift"


class FeedbackShadowGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="xtouch-j4-gate-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        source = SOURCE.read_text()
        start = source.index("package struct CompactFeedbackComparison:")
        end = source.index("\npackage enum CompactFeedbackShadow", start)
        cls.declarations = source[start:end]
        method_start = source.index("    package static func compare(", end)
        method_end = source.index("    package static func stage(", method_start)
        cls.method = source[method_start:method_end]
        # Unused plan/scope payload types are inert strings. The full real comparison
        # record, raw UTF8 matches property, sink protocol and check method are exact.
        probe = (
            "import Foundation\n"
            "package typealias CompactFeedbackPlan = String\n"
            "package typealias CompactFeedbackProof = String\n"
            "package typealias CompactFeedbackScope = String\n"
            "package typealias CompactFeedbackBytes = String\n"
            + cls.declarations
            + "\npackage enum CompactFeedbackShadow {\n"
            + cls.method
            + "}\n"
            + "let mode = CommandLine.arguments[1]\n"
            + 'let native = mode == "unicode" ? "\\u{e9}" : "native"\n'
            + 'let candidate = mode == "unicode" ? "e\\u{301}" : (mode == "mismatch" ? "other" : "native")\n'
            + 'let record = CompactFeedbackComparison(phase: "probe", plan: "opaque", proof: nil, currentScope: "scope", currentNative: "facts", native: native, candidate: candidate)\n'
            + "CompactFeedbackShadow.compare(record, audit: nil)\n"
            + 'print("COMPARE_RETURNED")\n'
        )
        cls.probe = cls.directory / "main.swift"
        cls.probe.write_text(probe)
        cls.binary = cls.directory / "feedback-gate"
        cls.evidence = (
            Path(os.environ["XTOUCH_J4_GATE_PROBE_EVIDENCE_ROOT"])
            if os.environ.get("XTOUCH_J4_GATE_PROBE_EVIDENCE_ROOT")
            else None
        )
        argv = ["swiftc", "-D", "DEBUG", "-package-name", "FeedbackProbe", str(cls.probe), "-o", str(cls.binary)]
        compiled = subprocess.run(argv, capture_output=True, text=True, timeout=60, cwd=cls.directory)
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)
        ast_argv = ["swiftc", "-D", "DEBUG", "-package-name", "FeedbackProbe", "-dump-ast", str(cls.probe)]
        ast = subprocess.run(ast_argv, capture_output=True, text=True, timeout=60, cwd=cls.directory)
        if ast.returncode:
            raise AssertionError(ast.stdout + ast.stderr)
        cls.metadata = {
            "actual_source": str(SOURCE),
            "actual_source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "declarations_sha256": hashlib.sha256(cls.declarations.encode()).hexdigest(),
            "method_sha256": hashlib.sha256(cls.method.encode()).hexdigest(),
            "probe_sha256": hashlib.sha256(probe.encode()).hexdigest(),
            "compile_argv": argv,
            "compile_exit": compiled.returncode,
            "ast_argv": ast_argv,
            "ast_exit": ast.returncode,
            "payload_stubs": "unused opaque plan/proof/scope/native value fields only; checker and UTF8 comparison exact",
            "runs": [],
        }
        if cls.evidence:
            cls.evidence.mkdir(parents=True, exist_ok=False)
            (cls.evidence / "main.swift").write_text(probe)
            (cls.evidence / "probe.ast.txt").write_text(ast.stdout + ast.stderr)
            (cls.evidence / "actual-declarations.swift").write_text(cls.declarations + cls.method)

    def run_probe(self, mode):
        environment = dict(os.environ, SWIFT_BACKTRACE="enable=no")
        argv = [str(self.binary), mode]
        result = subprocess.run(argv, cwd=self.directory, env=environment, capture_output=True, text=True, timeout=15)
        self.metadata["runs"].append({"argv": argv, "exit_code": result.returncode})
        if self.evidence:
            (self.evidence / (mode + ".stdout")).write_text(result.stdout)
            (self.evidence / (mode + ".stderr")).write_text(result.stderr)
            (self.evidence / "identity.json").write_text(json.dumps(self.metadata, indent=2) + "\n")
        return result

    def test_equal_actual_comparison_returns_normally(self):
        result = self.run_probe("equal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("COMPARE_RETURNED", result.stdout)

    def test_mismatch_and_canonically_equal_different_utf8_both_fail(self):
        for mode in ("mismatch", "unicode"):
            with self.subTest(mode=mode):
                result = self.run_probe(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("J4 feedback shadow mismatch", result.stderr)
                self.assertNotIn("COMPARE_RETURNED", result.stdout)
