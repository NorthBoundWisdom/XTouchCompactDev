#!/usr/bin/env python3
"""Check explicit file/module roles and host-owned Swift declaration/member references."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROLE_EDGES = {
    "values": {"values"},
    "runtime": {"values", "runtime"},
    "device": {"values", "runtime", "device"},
    "bridge": {"values", "runtime", "device", "bridge"},
    "transport": {"values", "runtime", "device", "bridge", "transport"},
    "composition": {"values", "runtime", "device", "bridge", "transport", "composition"},
}
PURE_IMPORTS = {
    "values": {"Foundation", "SurfacePluginContracts"},
    "runtime": {"Foundation", "SurfacePluginContracts", "RemoteToolContracts", "SurfaceControlContracts"},
    "device": {"Foundation", "SurfacePluginContracts", "SurfaceControlContracts"},
}
IMPORTS = re.compile(
    r"^[ \t]*(?:(?:@\w+(?:\([^()\n]*\))?|public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:struct|enum|class|protocol|func|var|typealias)\s+)?(\w+)",
    re.MULTILINE,
)
TOKENS = re.compile(r"[A-Za-z_][A-Za-z_0-9]*|[^\s]")
DECLARATIONS = {"struct", "enum", "class", "protocol", "actor", "typealias"}


def swift_code(text):
    """Remove nested comments and literal text, retaining executable string interpolation."""
    output = list(text)
    length = len(text)

    def blank(start, end):
        for index in range(start, end):
            if output[index] != "\n":
                output[index] = " "

    def scan(start, stop_paren=False):
        index, parens = start, 0
        while index < length:
            if stop_paren and text[index] == ")" and parens == 0:
                return index
            if text.startswith("//", index):
                end = text.find("\n", index)
                end = length if end < 0 else end
                blank(index, end)
                index = end
            elif text.startswith("/*", index):
                end, depth = index + 2, 1
                while end < length and depth:
                    if text.startswith("/*", end):
                        depth += 1
                        end += 2
                    elif text.startswith("*/", end):
                        depth -= 1
                        end += 2
                    else:
                        end += 1
                blank(index, end)
                index = end
            else:
                match = re.match(r'(#{0,8})("""|")', text[index:])
                if match:
                    hashes, quote = match.groups()
                    begin = index
                    index += len(match.group())
                    blank(begin, index)
                    literal_start = index
                    close, interpolation = quote + hashes, "\\" + hashes + "("
                    while index < length:
                        if text.startswith(close, index):
                            blank(literal_start, index + len(close))
                            index += len(close)
                            break
                        if text.startswith(interpolation, index):
                            blank(literal_start, index + len(interpolation) - 1)
                            expression_start = index + len(interpolation)
                            expression_end = scan(expression_start, stop_paren=True)
                            index = expression_end + 1
                            literal_start = index
                        elif not hashes and text[index] == "\\":
                            index += 2
                        else:
                            index += 1
                    else:
                        blank(literal_start, length)
                else:
                    if stop_paren:
                        if text[index] == "(":
                            parens += 1
                        elif text[index] == ")":
                            parens -= 1
                    index += 1
        return index

    scan(0)
    return "".join(output)


def source_symbols(code):
    tokens = TOKENS.findall(code)
    declarations, members = [], []
    owners, depth, pending = [], 0, None
    for index, token in enumerate(tokens):
        if token in DECLARATIONS | {"extension"} and index + 1 < len(tokens):
            name = tokens[index + 1]
            if name.isidentifier() and name not in {"func", "var", "let"}:
                if token != "extension":
                    declarations.append(name)
                end = index + 1
                if token == "extension":
                    while end + 2 < len(tokens) and tokens[end + 1] == "." and tokens[end + 2].isidentifier():
                        end += 2
                    name = tokens[end]
                if token != "typealias":
                    pending = (name, token == "extension")
        elif token == "{":
            depth += 1
            if pending is not None:
                owners.append((depth, *pending))
                pending = None
        elif token == "}":
            if owners and owners[-1][0] == depth:
                owners.pop()
            depth -= 1
        elif owners and owners[-1][0] == depth and token in {"func", "var", "let", "init"}:
            name = "init" if token == "init" else (tokens[index + 1] if index + 1 < len(tokens) else "")
            if name.isidentifier():
                members.append((owners[-1][1], name, owners[-1][2]))
    bindings = defaultdict(set)
    for name, value in re.findall(r"\b(\w+)\s*:\s*(?:[A-Z]\w*\.)?([A-Z]\w*)", code):
        bindings[name].add(value)
    return tokens, declarations, members, bindings


def target_dependencies(target):
    return {
        value.get("byName", value.get("target", value.get("product", [""])))[0]
        for value in target.get("dependencies", [])
    }


def check_tree(root, manifest, package=None):
    root = Path(root)
    roles = manifest["files"]
    targets = manifest["targets"]
    errors, edges = [], []
    actual = {str(path.relative_to(root)) for path in (root / "Sources").rglob("*.swift")}
    for path in sorted(actual - roles.keys()):
        errors.append("Unclassified production file: " + path)
    for path in sorted(roles.keys() - actual):
        errors.append("Missing classified production file: " + path)
    for path, role in roles.items():
        if role not in ROLE_EDGES:
            errors.append("Unknown file role: " + path)
    if package is not None:
        for target in package["targets"]:
            if target.get("type") == "test":
                continue
            name = target["name"]
            if name not in targets:
                errors.append("Unclassified production module: " + name)
                continue
            extra = target_dependencies(target) - set(targets[name]["dependencies"])
            if extra:
                errors.append("Forbidden module dependencies: " + name + " -> " + ",".join(sorted(extra)))
    parsed, declarations, members, member_owners = {}, defaultdict(set), defaultdict(set), defaultdict(set)
    for path in sorted(actual & roles.keys()):
        if roles[path] not in ROLE_EDGES:
            continue
        code = swift_code((root / path).read_text())
        parsed[path] = (code, *source_symbols(code))
        for name in parsed[path][2]:
            declarations[name].add(path)
        for owner, name, is_extension in parsed[path][3]:
            members[(owner, name)].add(path)
            if is_extension:
                member_owners[name].add(owner)

    def reference(path, destination, reason):
        source_role, target_role = roles[path], roles[destination]
        edges.append((path, destination, reason))
        if target_role not in ROLE_EDGES[source_role]:
            errors.append(
                f"Reverse declaration edge: {path} ({source_role}) -> {destination} ({target_role}) [{reason}]"
            )

    for path, (code, tokens, own_types, own_members, bindings) in parsed.items():
        role = roles[path]
        imports = IMPORTS.findall(code)
        source_target = path.split("/")[1]
        for imported in imports:
            if imported in targets:
                if imported != source_target and imported not in targets[source_target]["dependencies"]:
                    errors.append(f"Forbidden host module import: {path} -> {imported}")
            elif role in PURE_IMPORTS and imported not in PURE_IMPORTS[role]:
                errors.append(f"Forbidden pure-layer import: {path} -> {imported}")
        visible_targets = {source_target, *(module for module in imports if module in targets)}

        def visible(destinations):
            return {destination for destination in destinations if destination.split("/")[1] in visible_targets}

        # Construction through a bridge-only convenience initializer is still a reverse
        # dependency even though its type's declaration lives in runtime. Explicit validated
        # value entry points are listed in the manifest; no caller callback is involved.
        if role == "runtime":
            for type_name, label in manifest.get("validated_runtime_constructors", {}).items():
                for match in re.finditer(r"\b" + re.escape(type_name) + r"\s*(?:\.\s*init\s*)?\(", code):
                    tail = code[match.end() :]
                    if not re.match(r"\s*" + re.escape(label) + r"\s*:", tail):
                        errors.append(f"Runtime construction bypasses validated entry point: {path} -> {type_name}")
        external_imports = set(imports) - targets.keys()
        for index, token in enumerate(tokens):
            if token in declarations:
                prefix = tokens[index - 2] if index >= 2 and tokens[index - 1] == "." else None
                # A qualified external SDK type is not a coincidentally named host type.
                if prefix not in external_imports:
                    destinations = (
                        {destination for destination in declarations[token] if destination.split("/")[1] == prefix}
                        if prefix in targets
                        else {path}
                        if token in own_types
                        else visible(declarations[token])
                    )
                    for destination in destinations:
                        reference(path, destination, token)
            if index + 2 < len(tokens) and tokens[index + 1] == "." and tokens[index + 2].isidentifier():
                member = tokens[index + 2]
                owners = ({token} if token in declarations else set()) | bindings.get(token, set())
                for owner in owners:
                    for destination in visible(members.get((owner, member), set())):
                        reference(path, destination, owner + "." + member)
            if token == "." and index + 1 < len(tokens):
                member = tokens[index + 1]
                owners = member_owners.get(member, set())
                if member != "init" and len(owners) == 1 and (index == 0 or not tokens[index - 1].isidentifier()):
                    owner = next(iter(owners))
                    for destination in visible(members[(owner, member)]):
                        reference(path, destination, "inferred " + owner + "." + member)
    return {
        "errors": sorted(set(errors)),
        "file_count": len(actual),
        "roles": {role: sum(value == role for value in roles.values()) for role in ROLE_EDGES},
        "edges": [list(edge) for edge in sorted(set(edges))],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.root / "configs/host_layers.json").read_text())
    package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=args.root))
    report = check_tree(args.root, manifest, package)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "edges"}, indent=2))
    raise SystemExit(bool(report["errors"]))


if __name__ == "__main__":
    main()
