#!/usr/bin/env python3
"""Development remote hardware: reach a controller plugged into another Mac over SSH.

    python3 tools/remote_hardware.py deploy  --ssh henrys-mac-mini
    python3 tools/remote_hardware.py devices --ssh henrys-mac-mini
    python3 tools/remote_hardware.py connect --ssh henrys-mac-mini
    python3 tools/remote_hardware.py status  --ssh henrys-mac-mini
    python3 tools/remote_hardware.py listen [--ssh henrys-mac-mini] > capture.jsonl

`status` is read-only: it compares the deployed binary with a local build, lists bridges
already running on the remote Mac and local clients, and shows whether the controller is
visible to CoreMIDI there. It starts nothing.
`listen` is a passive raw capture (JSON lines on stdout, SysEx included; it cannot send
MIDI). Without --ssh it listens on this Mac; with --ssh on the remote Mac. Ctrl-C stops it.
`deploy` builds XTouchRemoteMIDI and copies it to ~/.xtouch-remote/ on the remote Mac.
`connect` runs the local client in the foreground; while the remote controller is present,
this Mac shows a MIDI port pair named "X-TOUCH COMPACT (via <host>)". Stop with Ctrl-C.
No listening port is opened on either Mac: the MIDI stream is the SSH session's stdio.
"""

import argparse
import hashlib
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
    # Build output goes to stderr so stdout stays clean for `listen` captures.
    subprocess.run(command, cwd=ROOT, check=True, stdout=sys.stderr)
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


# Fixed remote command: no user text is interpolated. Prints the deployed binary's hash,
# any running bridges, and the device listing, with markers the parser below expects.
_STATUS_SCRIPT = (
    f"cd ~ && f={REMOTE_DIRECTORY}/{PRODUCT}; "
    'if [ -x "$f" ]; then echo "sha256 $(shasum -a 256 "$f" | cut -d" " -f1)"; else echo "sha256 missing"; fi; '
    'echo "bridges $(pgrep -f "$f bridge" | tr "\\n" " ")"; '
    'if [ -x "$f" ]; then echo "--devices"; "$f" devices; fi'
)


def parse_status(text: str) -> dict:
    """Parse the fixed status script's output. Unknown lines are ignored."""
    result: dict = {"remote_sha256": None, "bridges": [], "controller": None, "devices": []}
    in_devices = False
    for line in text.splitlines():
        if line.startswith("sha256 "):
            value = line.split(" ", 1)[1].strip()
            result["remote_sha256"] = None if value == "missing" else value
        elif line.startswith("bridges"):
            result["bridges"] = [pid for pid in line.split()[1:] if pid.isdigit()]
        elif line == "--devices":
            in_devices = True
            result["controller"] = False
        elif in_devices and line.startswith("  "):
            result["devices"].append(line.strip())
            if "[controller" in line and "offline" not in line:
                result["controller"] = True
    return result


def local_clients(host: str) -> list[str]:
    """PIDs of local clients for this host (exact argument match, no shell)."""
    listing = subprocess.run(["pgrep", "-fl", f"{PRODUCT} client --ssh {host}"], capture_output=True, text=True)
    return [line.split()[0] for line in listing.stdout.splitlines() if line.split() and line.split()[0].isdigit()]


def status(host: str) -> int:
    local = build()
    local_hash = hashlib.sha256(local.read_bytes()).hexdigest()
    remote = subprocess.run(["ssh", *SSH_OPTIONS, "--", host, _STATUS_SCRIPT], capture_output=True, text=True)
    if remote.returncode != 0:
        print(f"SSH to {host} failed (exit {remote.returncode}): {remote.stderr.strip()}")
        return 1
    state = parse_status(remote.stdout)
    deployed = state["remote_sha256"]
    print(
        f"Remote binary : {'not deployed' if deployed is None else ('current' if deployed == local_hash else 'outdated, run deploy')}"
    )
    print(f"Remote bridges: {', '.join(state['bridges']) or 'none running'}")
    print(f"Local clients : {', '.join(local_clients(host)) or 'none running'}")
    controller = state["controller"]
    print(
        f"Controller    : {'unknown (deploy first)' if controller is None else ('visible' if controller else 'not visible')}"
    )
    for device in state["devices"]:
        print(f"    {device}")
    return 0


def listen(host: str | None) -> None:
    if host is None:
        command = [str(build()), "listen"]
    else:
        command = ["ssh", *SSH_OPTIONS, "-T", "--", host, f"{REMOTE_DIRECTORY}/{PRODUCT}", "listen"]
    try:
        subprocess.run(command, check=True)
    except KeyboardInterrupt:
        pass


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
    parser.add_argument("action", choices=["deploy", "devices", "connect", "status", "listen"])
    parser.add_argument(
        "--ssh", type=validated_host, help="SSH host alias of the Mac with the controller (optional for listen)"
    )
    parser.add_argument("--label", type=validated_host, help="Name shown in the port name; defaults to the host")
    args = parser.parse_args()
    if args.action == "listen":
        listen(args.ssh)
        return
    if args.ssh is None:
        parser.error(f"{args.action} requires --ssh")
    if args.action == "deploy":
        deploy(args.ssh)
    elif args.action == "devices":
        devices(args.ssh)
    elif args.action == "status":
        sys.exit(status(args.ssh))
    else:
        connect(args.ssh, args.label)


if __name__ == "__main__":
    main()
