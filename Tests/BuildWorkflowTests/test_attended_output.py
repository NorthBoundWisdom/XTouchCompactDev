"""Prepared field documents retain their bytes and cannot escape a standalone checkout by default."""

import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_SOURCE = ROOT / "configs/hardware_attended.py"
GOLDEN = {
    "xtouch-attended.json": "2183cfde02334e103e7a8d321558015eed2f3162421f11d5a534a5a3f1db3d72",
    "xtouch-attended.md": "6feedd77a48a36d8c8226d8e9ac75e8483dea023e9e51c529533498f9d35f193",
}


class AttendedOutputTests(unittest.TestCase):
    def standalone(self, parent):
        # A minimal filesystem fixture, not another Git checkout or a device connection.
        repo = parent / "independent-controller"
        (repo / "configs").mkdir(parents=True)
        script = repo / "configs/hardware_attended.py"
        shutil.copy2(SCRIPT_SOURCE, script)
        sdk = repo / "build/dependencies/SurfacePlugins/clients/python/surface_control"
        shutil.copytree(
            ROOT / "build/dependencies/SurfacePlugins/clients/python/surface_control",
            sdk,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        return repo, script

    def check_document_bytes(self, output):
        for name, digest in GOLDEN.items():
            self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest, name)

    def test_standalone_default_stays_in_repository_and_copied_runner_keeps_context(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            repo, script = self.standalone(parent)
            subprocess.run([sys.executable, "-B", str(script), "prepare"], cwd=parent, check=True, capture_output=True)
            self.assertFalse((parent / "build/e").exists())
            self.check_document_bytes(repo / "build/e")
            runner = repo / "build/e/xtouch/field.py"
            subprocess.run([sys.executable, "-B", str(runner), "prepare"], cwd=parent, check=True, capture_output=True)
            self.assertFalse((parent / "build/e").exists())
            self.check_document_bytes(repo / "build/e")

    def test_explicit_workspace_keeps_historical_document_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            repo, script = self.standalone(parent)
            workspace = parent / "chosen-workspace"
            subprocess.run(
                [sys.executable, "-B", str(script), "prepare", "--workspace-root", str(workspace)],
                cwd=parent,
                check=True,
                capture_output=True,
            )
            self.assertFalse((repo / "build/e").exists())
            self.assertFalse((parent / "build/e").exists())
            self.check_document_bytes(workspace / "build/e")
            runner = workspace / "build/e/xtouch/field.py"
            subprocess.run([sys.executable, "-B", str(runner), "prepare"], cwd=parent, check=True, capture_output=True)
            self.check_document_bytes(workspace / "build/e")
