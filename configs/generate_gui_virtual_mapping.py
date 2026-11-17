#!/usr/bin/env python3
"""Generate caller-owned display mapping from the explicit GUI simulation discovery."""

import argparse
import copy
import json
import zipfile
from pathlib import Path


def mapping_for(discovery, template):
    profile = discovery.get("profile", {})
    if not (
        discovery.get("source") == "simulation"
        and discovery.get("contract_version") in ("1.3", "1.5")
        and profile.get("id") == "xtouch.compact.gui.virtual"
        and profile.get("version") == "1"
        and "x.xtouch.gui_virtual" in profile.get("capabilities", [])
    ):
        raise ValueError("An explicit GUI virtual simulation discovery is required")
    candidates = [
        p
        for p in template["profiles"]
        if p.get("source") == "simulation"
        and p.get("profile_id") == "xtouch.compact.standard.simulation"
        and p.get("profile_version") == "1.3"
    ]
    if len(candidates) != 1:
        raise ValueError("The pinned SDK has no unique Compact software template")
    selected = copy.deepcopy(candidates[0])
    controls = {c["id"]: c for c in profile["controls"]}
    for target in selected["targets"]:
        if (
            target["control_id"] not in controls
            or target["kind"] not in controls[target["control_id"]]["feedback_kinds"]
        ):
            raise ValueError("The GUI does not declare a required display capability")
    selected.update(profile_id=profile["id"], profile_version=profile["version"])
    return {"schema_version": 1, "profiles": [selected]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-zip", type=Path, required=True)
    parser.add_argument("--discovery", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    with zipfile.ZipFile(args.sdk_zip) as sdk:
        template = json.loads(sdk.read("surface_panel_demo/mappings/compact.json"))
    result = mapping_for(json.loads(args.discovery.read_text()), template)
    with args.output.open("x") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print("Generated caller mapping for GUI simulation; physical_evidence=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
