#!/usr/bin/env python3
"""Render isolated mock SwiftUI previews; never capture the user's desktop or hardware."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["python3", "configs/macos_workflow.py", "build"], cwd=ROOT, check=True)
executable = ROOT / "build/app/debug/XTouchCompactApp.app/Contents/MacOS/XTouchCompactApp"
for language in ["en", "zh-Hans", "zh-Hant"]:
    output = ROOT / f"build/screenshots/{language}.png"
    subprocess.run(
        [str(executable), "--integration-test", "--snapshot-output", str(output), "-appLanguage", language],
        cwd=ROOT,
        check=True,
        timeout=30,
    )
    assert output.is_file()
    print(output)

for scene in ["settings", "parameters"]:
    output = ROOT / f"build/screenshots/{scene}.png"
    subprocess.run(
        [
            str(executable),
            "--integration-test",
            "--snapshot-output",
            str(output),
            "--snapshot-scene",
            scene,
            "-appLanguage",
            "en",
        ],
        cwd=ROOT,
        check=True,
        timeout=30,
    )
    assert output.is_file()
    print(output)
