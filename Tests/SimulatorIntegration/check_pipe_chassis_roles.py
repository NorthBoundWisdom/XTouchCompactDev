#!/usr/bin/env python3
"""Read-only Pipe role assembly probe against the simulator's real --describe output.

No Pipe source is modified or monkey-patched. A blocked resolution is reported as such;
independent supplier descriptor checks do not claim that Pipe accepted contract 1.2.
"""

import argparse
import copy
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
CONTROLS = {
    "enable": ("a.touch.1", "button", "boolean", [], True),
    "linear": ("a.fader.1", "absolute", "scalar", ["value"], False),
    "steer": ("a.encoder.9", "absolute", "scalar", ["value"], False),
    "stop": ("a.button.3", "button", "boolean", ["indicator"], False),
    "speed_feedback": ("a.encoder.10", "absolute", "scalar", ["value"], False),
    "steer_feedback": ("a.encoder.11", "absolute", "scalar", ["value"], False),
    "stopped_feedback": ("a.button.4", "button", "boolean", ["indicator"], False),
}


def check(binary, pipe_root):
    discovery = json.loads(subprocess.check_output([str(binary.resolve()), "--describe"], text=True))["discovery"]
    rows = {row["id"]: row for row in discovery["profile"]["controls"]}
    selected = {}
    for role, (identifier, kind, encoding, feedback, hold) in CONTROLS.items():
        row = rows[identifier]
        assert (row["input_kind"], row["encoding"], row["feedback_kinds"]) == (kind, encoding, feedback)
        assert bool(row.get("hold")) == hold
        if discovery["contract_version"] == "1.2":
            assert row["accepts_input"] is True
        selected[role] = row
    report = {
        "contract_version": discovery["contract_version"],
        "profile_version": discovery["profile"]["version"],
        "mapping_revision": discovery["expected"]["mapping_revision"],
        "supplier_descriptor_checks": "passed",
        "controls": selected,
    }
    provider = pipe_root / "drivers/bcr_provider"
    example = pipe_root / "tools/surface_sim_chassis_roles.example.json"
    if not provider.is_dir() or not example.is_file():
        return {**report, "pipe_resolution": "skipped", "reason": "Pipe checkout is unavailable"}
    sys.path.insert(0, str(provider))
    sys.path.insert(0, str(ROOT / "build/dependencies/SurfacePlugins/clients/python"))
    from pipe_bcr_provider.surface_sim.delivery import CONTRACT_VERSIONS, SurfaceConsumerError
    from pipe_bcr_provider.surface_sim.roles import REGISTERED_CAPABILITIES, resolve_chassis_roles
    from surface_control import mapping_revision

    config = json.loads(example.read_text())
    binding = next(row for row in config["profiles"] if row["profile_id"] == discovery["profile"]["id"])
    binding["profile_version"] = discovery["profile"]["version"]
    binding["mapping_revision"] = discovery["expected"]["mapping_revision"]
    report["pipe_contract_versions"] = sorted(CONTRACT_VERSIONS)
    report["pipe_missing_capabilities"] = sorted(
        capability for capability in discovery["profile"]["capabilities"]
        if not capability.startswith("x.") and capability not in REGISTERED_CAPABILITIES
    )
    try:
        result = resolve_chassis_roles(config, discovery, mapping_revision=mapping_revision)
        report.update(pipe_resolution="passed", resolved_controls=[result.enable.control_id, result.linear.control_id,
            result.steer.control_id, result.stop_control_id], resolved_feedback=sorted(result.feedback))
    except SurfaceConsumerError as error:
        report.update(pipe_resolution="blocked", pipe_error={"code": error.code, "message": str(error)})
        # Probe the version-allowlist boundary separately, without changing any imported code.
        explicit = copy.deepcopy(config)
        explicit["contract_versions"] = [discovery["contract_version"]]
        try:
            resolve_chassis_roles(explicit, discovery, mapping_revision=mapping_revision)
        except SurfaceConsumerError as allowlist_error:
            report["explicit_version_probe"] = {"code": allowlist_error.code, "message": str(allowlist_error)}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/XTouchSurfaceSimulator")
    parser.add_argument("--pipe-root", type=Path, default=Path.home() / "Documents/RobimPipe/robimweld_pipe")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = check(args.binary, args.pipe_root)
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
