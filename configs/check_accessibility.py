#!/usr/bin/env python3
"""Check SwiftUI primitive identifier coverage and unique source templates; never accesses the desktop."""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from configs.check_host_layers import swift_code

KINDS = "Button|Toggle|Picker|Slider|TextField|TextEditor|Stepper|Menu|DisclosureGroup|SettingsLink"


def balanced(code, position):
    pairs = {"(": ")", "{": "}", "[": "]"}
    stack = [pairs[code[position]]]
    index = position + 1
    while stack and index < len(code):
        if code[index] in pairs:
            stack.append(pairs[code[index]])
        elif code[index] == stack[-1]:
            stack.pop()
        index += 1
    return index


def skip(code, at):
    while at < len(code) and code[at].isspace():
        at += 1
    return at


def end_init(code, at):
    at = skip(code, at)
    if code[at] == "(":
        at = skip(code, balanced(code, at))
    if at < len(code) and code[at] == "{":
        at = balanced(code, at)
    while True:
        named = re.match(r"\s*\w+\s*:\s*(?=\{)", code[at:])
        if not named:
            break
        at = balanced(code, at + named.end())
    return at


def controls(text):
    code = swift_code(text)
    rows = []
    for match in re.finditer(r"\b(" + KINDS + r")\s*(?=[({])", code):
        end = end_init(code, match.end())
        at = end
        modifiers = []
        while True:
            modifier = re.match(r"\s*\.\s*(\w+)\s*(?=[({])", code[at:])
            if not modifier:
                break
            modifiers.append(modifier[1])
            at = end_init(code, at + modifier.end())
        rows.append((match.group(1), match.start(), end, modifiers, []))
    return rows


def check(root=ROOT):
    missing, templates, duplicates = [], {}, []
    count = 0
    for path in sorted((root / "Sources/XTouchCompactApp").glob("*.swift")):
        source = path.read_text()
        for kind, start, end, modifiers, _ in controls(source):
            count += 1
            if "accessibilityIdentifier" not in modifiers:
                missing.append(f"{path.name}:{source.count(chr(10), 0, start) + 1}: {kind}")
        for match in re.finditer(r'\.accessibilityIdentifier\("((?:[^"\\]|\\.)*)"\)', source):
            identifier = match[1]
            if identifier in templates:
                duplicates.append(identifier)
            templates[identifier] = path.name
    panel = (root / "Sources/XTouchCompactApp/SurfacePanelView.swift").read_text()
    required = [
        "fader(fader.index)",
        "faderTouch(fader.index)",
        "encoder(encoder.index)",
        "encoderPush(encoder.index)",
        "button(button.index)",
    ]
    for binding in required:
        if f".accessibilityIdentifier(CompactControl.{binding}.accessibilityID)" not in panel:
            missing.append("Panel binding " + binding)
    return {"controls": count, "identifier_templates": len(templates), "missing": missing, "duplicates": duplicates}


def main():
    import json

    result = check()
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(bool(result["missing"] or result["duplicates"]))


if __name__ == "__main__":
    raise SystemExit(main())
