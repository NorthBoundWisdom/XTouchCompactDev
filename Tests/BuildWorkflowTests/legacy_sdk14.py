"""Real frozen1.4 inputs for unchanged historical packaging assertions; no current SDK masquerade."""

import hashlib
import json
import subprocess
import tempfile
import zipfile
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from configs import package_surface_hardware as hw
from configs import package_surface_simulator as sim

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Tests/Fixtures/SDK14"


class LegacyPackagingFixture:
    def __init__(self, test):
        self.temp = tempfile.TemporaryDirectory(prefix="c-sdk14-fixture-")
        test.addCleanup(self.temp.cleanup)
        self.shared = Path(self.temp.name)
        records = json.loads((FIXTURE / "provenance.json").read_text())["records"]
        for record in records:
            body = (FIXTURE / record["path"]).read_bytes()
            test.assertEqual(hashlib.sha256(body).hexdigest(), record["sha256"])
        payload = next(r for r in records if r["path"] == "locked-shared-files.zip")
        with zipfile.ZipFile(FIXTURE / payload["path"]) as z:
            test.assertEqual(set(z.namelist()), set(payload["members"]))
            for name, digest in payload["members"].items():
                test.assertEqual(hashlib.sha256(z.read(name)).hexdigest(), digest)
            z.extractall(self.shared)

        # A temporary fixture repository has its own honest tree identity. Original12ba
        # provenance is separately frozen above; never pretend this subset commit is12ba.
        def git(*args):
            subprocess.run(
                ["git", *args], cwd=self.shared, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )

        git("init", "-q")
        git("add", ".")
        git(
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "frozen SDK14 packaging inputs",
        )
        metadata = json.loads((FIXTURE / "packaging-metadata.json").read_text())
        stack = ExitStack()
        test.addCleanup(stack.close)
        stack.enter_context(
            patch.multiple(
                sim,
                SHARED=self.shared,
                SDK_VERSION="1.4.0",
                SDK_ZIP="surface-control-sdk-1.4.0.zip",
                TEST_SUPPORT_ZIP="surface-control-test-support-1.4.0.zip",
                SHARED_FILES=metadata["shared_files"]["package_surface_simulator.py"],
            )
        )
        stack.enter_context(
            patch.multiple(
                hw,
                SHARED=self.shared,
                SDK_ZIP="surface-control-sdk-1.4.0.zip",
                SHARED_FILES=metadata["shared_files"]["package_surface_hardware.py"],
            )
        )
        self.sdk_archive = FIXTURE / "surface-control-sdk-1.4.0.zip"
