#!/usr/bin/env python3
"""Development remote hardware: reach a controller plugged into another Mac over SSH.

    python3 tools/remote_hardware.py deploy  --ssh henrys-mac-mini
    python3 tools/remote_hardware.py devices --ssh henrys-mac-mini
    python3 tools/remote_hardware.py connect --ssh henrys-mac-mini

`deploy` builds XTouchRemoteMIDI and copies it to ~/.xtouch-remote/ on the remote Mac.
`connect` runs the local client in the foreground; while the remote controller is present,
this Mac shows a MIDI port pair named "X-TOUCH COMPACT (via <host>)". Stop with Ctrl-C.
No listening port is opened on either Mac: the MIDI stream is the SSH session's stdio.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from configs.build_paths import build_path  # noqa: E402

PRODUCT = "XTouchRemoteMIDI"
REMOTE_DIRECTORY = ".xtouch-remote"
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
_HOST = re.compile(r"^(?![-.@])(?!.*@.*@)[A-Za-z0-9._:@-]{1,253}$")


def validated_host(value: str) -> str:
    """Mirror the Swift client's rule: never pass option-like or shell-active text to ssh."""
    if not _HOST.match(value):
        raise argparse.ArgumentTypeError(f"invalid SSH host: {value!r}")
    return value


def build() -> Path:
    scratch = build_path(ROOT, "remote-midi")
    command = ["swift", "build", "--configuration", "release", "--scratch-path", str(scratch), "--product", PRODUCT]
    subprocess.run(command, cwd=ROOT, check=True)
    binary_directory = subprocess.run(
        [*command[:-2], "--show-bin-path"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()
    return Path(binary_directory) / PRODUCT


def deploy(host: str) -> None:
    binary = build()
    subprocess.run(["ssh", *SSH_OPTIONS, "--", host, "mkdir", "-p", REMOTE_DIRECTORY], check=True)
    # Copy to a temporary name, then rename: a running bridge keeps its old inode.
    staged = f"{REMOTE_DIRECTORY}/{PRODUCT}.new"
    subprocess.run(["scp", "-q", *SSH_OPTIONS, str(binary), f"{host}:{staged}"], check=True)
    subprocess.run(["ssh", *SSH_OPTIONS, "--", host, "mv", "-f", staged, f"{REMOTE_DIRECTORY}/{PRODUCT}"], check=True)
    print(f"Deployed {PRODUCT} to {host}:~/{REMOTE_DIRECTORY}/")


def devices(host: str) -> None:
    subprocess.run(["ssh", *SSH_OPTIONS, "--", host, f"{REMOTE_DIRECTORY}/{PRODUCT}", "devices"], check=True)


def connect(host: str, label: str | None) -> None:
    arguments = [str(build()), "client", "--ssh", host]
    if label:
        arguments += ["--label", label]
    try:
        subprocess.run(arguments, check=True)
    except KeyboardInterrupt:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["deploy", "devices", "connect"])
    parser.add_argument(
        "--ssh", required=True, type=validated_host, help="SSH host alias of the Mac with the controller"
    )
    parser.add_argument("--label", type=validated_host, help="Name shown in the port name; defaults to the host")
    args = parser.parse_args()
    if args.action == "deploy":
        deploy(args.ssh)
    elif args.action == "devices":
        devices(args.ssh)
    else:
        connect(args.ssh, args.label)


if __name__ == "__main__":
    main()
