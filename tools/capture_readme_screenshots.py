#!/usr/bin/env python3
"""Render app-owned isolated previews; preserve trace and process samples on timeout."""

import argparse
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from configs.build_paths import build_path


def validate_png(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"Missing or invalid PNG: {path}")
    width, height = struct.unpack(">II", data[16:24])
    if width == 0 or height == 0:
        raise ValueError(f"Empty preview dimensions: {path}")


def capture(executable: Path, output: Path, language: str, scene: str = "console", *, timeout: float = 30) -> None:
    output.unlink(missing_ok=True)  # A stale screenshot must never satisfy this run.
    output.parent.mkdir(parents=True, exist_ok=True)
    trace = output.with_suffix(".log")
    command = [
        str(executable),
        "--integration-test",
        "--snapshot-output",
        str(output),
        "--snapshot-scene",
        scene,
        "-appLanguage",
        language,
    ]
    with trace.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            sample = output.with_suffix(".sample.txt")
            try:
                subprocess.run(
                    ["sample", str(process.pid), "1", "1", "-file", str(sample)],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=5,
                    check=False,
                )
            finally:
                process.kill()
                process.wait(timeout=5)
            print(trace.read_text(), flush=True)
            if sample.exists():
                print("\n".join(sample.read_text().splitlines()[:100]), flush=True)
            raise TimeoutError(f"Preview {scene}/{language} timed out; diagnostics: {trace}") from None
    print(trace.read_text(), flush=True)
    if result != 0:
        raise subprocess.CalledProcessError(result, command)
    validate_png(output)
    print(output, flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use the existing Debug app for diagnostics.")
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run(["python3", "configs/setup_local_project.py"], cwd=ROOT, check=True)
        subprocess.run(["python3", "configs/macos_workflow.py", "build"], cwd=ROOT, check=True)
    executable = ROOT / "build/app/debug/XTouchCompactApp.app/Contents/MacOS/XTouchCompactApp"
    output = build_path(ROOT, "screenshots/en.png")
    build_path(ROOT, "screenshots/en.log")
    build_path(ROOT, "screenshots/en.sample.txt")
    capture(executable, output, "en", "readme-console")
    for scene, name in (
        ("settings", "settings"),
        ("parameters", "parameters"),
        ("organize-page", "organization"),
        ("offline-capture", "offline-capture"),
    ):
        output = build_path(ROOT, f"screenshots/{name}.png")
        build_path(ROOT, f"screenshots/{name}.log")
        build_path(ROOT, f"screenshots/{name}.sample.txt")
        capture(executable, output, "en", scene)


if __name__ == "__main__":
    main()
