"""The delivered checker contract also runs against real loopback hosts in Linux CI."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_http_simulator import ROOT, SHARED, TOKEN, RunningSimulator


class LiveConformanceHTTPTests(unittest.TestCase):
    def test_four_fixtures_with_truthful_default_role_map(self):
        roles = ROOT / "examples/surface_simulator/conformance-roles.json"
        role_map = json.loads(roles.read_text())
        reports = ROOT / "build/conformance-http"
        reports.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as directory:
            # Quota behavior depends on host configuration and is not fixture timing.
            # This isolated run allows the checker to exercise its serial wire steps.
            host = RunningSimulator(directory, "conformance.http", extra=("--write-limit", "10000"))
            token_file = Path(directory) / "token"
            token_file.write_text(TOKEN)
            token_file.chmod(0o600)
            try:
                for fixture in sorted((SHARED / "fixtures").glob("surface-control-software-v*.json")):
                    with self.subTest(fixture=fixture.name):
                        report_path = reports / fixture.name
                        environment = {**os.environ, "PYTHONPATH": str(SHARED / "clients/python")}
                        completed = subprocess.run([sys.executable, "-B", "-m", "surface_conformance",
                            "--url", host.ready["url"], "--token-file", str(token_file), "--instance-id", "conformance.http",
                            "--fixture", str(fixture), "--roles", str(roles), "--report", str(report_path)],
                            cwd=directory, env=environment, capture_output=True, text=True, timeout=30)
                        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                        report = json.loads(report_path.read_text())
                        source = json.loads(fixture.read_text())
                        self.assertEqual(report["counts"]["fail"], 0)
                        self.assertGreater(report["counts"]["pass"], 0)
                        self.assertEqual(sum(report["counts"].values()), sum(len(row["steps"]) for row in source["scenarios"]))
                        self.assertEqual(report["roles"], role_map["fixtures"][source["scenario_id"]]["roles"])
                        for step in report["steps"]:
                            if step["status"] == "skip":
                                self.assertTrue(step.get("reason"), "Every skipped step needs a reason")
                        self.assertTrue(TOKEN not in completed.stdout + completed.stderr + report_path.read_text(),
                            "Checker output must omit credentials")
            finally:
                host.close()
