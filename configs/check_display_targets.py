#!/usr/bin/env python3
"""Generate/check a display catalogue from a binary's read-only --describe profile."""

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def render(description):
    discovery = description["discovery"]
    source = discovery["source"]
    if source not in ("simulation", "hardware"):
        raise ValueError("Unknown source")
    profile = discovery["profile"]
    controls = profile["controls"]
    if source == "hardware" and any(".fader." in row["id"] and row["feedback_kinds"] for row in controls):
        raise ValueError("Hardware faders must not declare any feedback kind")
    rows = [row for row in controls if row["feedback_kinds"] and ".fader." not in row["id"]]
    lines = [
        "# X-Touch display targets (" + source + ")",
        "",
        "Generated from the default read-only discovery profile; no MIDI addresses are handwritten.",
        "Profile: `" + profile["id"] + "` / `" + profile["version"] + "`.",
        "Faders are excluded from every panel catalogue. Hardware faders must declare no feedback kind.",
        "",
        "Discovery gives stable IDs, feedback kinds and ranges. It does not report the current ring style",
        "or physical qualification. The style/qualification notes below describe the existing host implementation;",
        "they are not new contract fields or evidence of a physical device preset.",
        "",
    ]
    if source == "hardware":
        lines += [
            "Each encoder value request already sends a single-style declaration before its ring value.",
            "This predates H; the physical preset is unread and has not been checked in attended acceptance.",
            "This is an implementation gap against preserving an unknown current preset, not permission to change it.",
            "Values: 0 off; 1–13 position; 14–26 blinking position; 27 all on; 28 all blinking.",
            "A/B targets share physical output addresses: matching layer input evidence is required; remote cannot select a layer.",
        ]
    else:
        lines += [
            "Encoder values are mapped to a position display in the existing simulator ring style.",
            "The default visual renderer uses single-position when no style is present; discovery does not expose style.",
        ]
    lines += [
        "",
        "| Stable ID | Kind | Allowed values | Current display style / knowledge | Default qualification |",
        "|---|---|---|---|---|",
    ]
    for row in rows:
        for kind in row["feedback_kinds"]:
            if kind == "value":
                span = row.get("feedback_range", row.get("range"))
                if not span:
                    raise ValueError("Value feedback without range: " + row["id"])
                values = f"{span['minimum']}..{span['maximum']}; step {span.get('step', 'unspecified')}"
                style = (
                    "single declared by service; physical preset unknown"
                    if source == "hardware"
                    else "position in simulator style; default renderer single"
                )
            elif kind == "indicator":
                values = "off / on / blink"
                style = "off / steady / blinking"
            else:
                raise ValueError("Unknown feedback kind: " + kind)
            qualification = (
                "software only; attended physical acceptance pending" if source == "hardware" else "simulation only"
            )
            lines.append(f"| `{row['id']}` | {kind} | {values} | {style} | {qualification} |")
    lines += [
        "",
        f"Display controls: {len(rows)}. This catalogue does not change profile eligibility or physical qualification.",
        "",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--contract", type=Path, help="Delivered control-contract.json (no binary or device access)")
    selection.add_argument("--binary", type=Path, help="Read-only --describe executable")
    parser.add_argument("--source", choices=["simulation", "hardware"])
    parser.add_argument("--table", type=Path, required=True)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.contract:
        description = json.loads(args.contract.read_text())
    else:
        command = [str(args.binary.resolve()), "--describe"]
        if args.source == "hardware":
            command += ["--receive-channel", "2", "--light-protocol", "observed114"]
        description = json.loads(subprocess.check_output(command))
    if args.source and description["discovery"]["source"] != args.source:
        raise ValueError("Source differs from requested catalogue")
    expected = render(description)
    if args.write:
        args.table.write_text(expected)
    elif args.table.read_text() != expected:
        raise ValueError("Display catalogue differs from discovery; regenerate it")
    print("Display catalogue matches " + description["discovery"]["source"] + " profile")


if __name__ == "__main__":
    main()
