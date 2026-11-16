#!/usr/bin/env python3
"""Generate an explicit demo-only mapping for this host's disclosed rehearsal profile."""

import argparse
import copy
import json
import zipfile
from pathlib import Path

try:
    from .surface_sdk_metadata import package_sdk
except ImportError:
    from surface_sdk_metadata import package_sdk


def mapping_for(contract, template):
    discovery = contract.get("discovery", {})
    profile = discovery.get("profile", {})
    if not (
        contract.get("owned_virtual_rehearsal") is True
        and contract.get("physical_evidence") is False
        and discovery.get("source") == "hardware"
        and discovery.get("contract_version") == "1.5"
        and profile.get("id") == "xtouch.compact.owned-virtual-rehearsal"
        and profile.get("version") == "1.5"
        and "session.owned_virtual_rehearsal" in profile.get("capabilities", [])
    ):
        raise ValueError("A disclosed owned-only rehearsal discovery is required")
    candidates = [
        p
        for p in template["profiles"]
        if p.get("source") == "hardware"
        and p.get("profile_id") == "xtouch.compact.standard.hardware"
        and p.get("profile_version") == "1.4"
    ]
    if len(candidates) != 1:
        raise ValueError("The pinned SDK has no unique Compact display template")
    selected = copy.deepcopy(candidates[0])
    controls = {c["id"]: c for c in profile["controls"]}
    for target in selected["targets"]:
        if (
            target["control_id"] not in controls
            or target["kind"] not in controls[target["control_id"]]["feedback_kinds"]
        ):
            raise ValueError("The rehearsal profile lacks a requested display capability")
        if ".fader." in target["control_id"]:
            raise ValueError("A display demo mapping cannot add mechanisms")
    selected["profile_id"] = profile["id"]
    selected["profile_version"] = profile["version"]
    return {"schema_version": 1, "profiles": [selected]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delivery", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    archive, version = package_sdk(args.delivery)
    if version != "1.5.0":
        raise ValueError("Owned rehearsal requires the explicit SDK 1.5 artifact")
    with zipfile.ZipFile(archive) as sdk:
        template = json.loads(sdk.read("surface_panel_demo/mappings/compact.json"))
    generated = mapping_for(json.loads(args.contract.read_text()), template)
    with args.output.open("x") as stream:
        json.dump(generated, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print("Generated demo-only rehearsal mapping; physical_evidence=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
