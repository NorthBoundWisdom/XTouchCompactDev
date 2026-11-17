#!/usr/bin/env python3
"""Check explicit file/module roles and host-owned Swift declaration/member references."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
ROLE_EDGES = {
    "values": {"values"},
    "runtime": {"values", "runtime"},
    "device": {"values", "runtime", "device"},
    "bridge": {"values", "runtime", "device", "bridge"},
    "transport": {"values", "runtime", "device", "bridge", "transport"},
    "composition": {"values", "runtime", "device", "bridge", "transport", "composition"},
}
PURE_IMPORTS = {
    "values": {"Foundation", "SurfacePluginContracts", "SurfaceDeviceContracts"},
    "runtime": {
        "Foundation",
        "SurfacePluginContracts",
        "RemoteToolContracts",
        "SurfaceControlContracts",
        "SurfaceDeviceContracts",
        "SurfaceBindingContext",
        "SurfaceFeedbackPlanning",
    },
    "device": {
        "Foundation",
        "SurfacePluginContracts",
        "SurfaceControlContracts",
        "SurfaceDeviceContracts",
        "SurfaceBindingContext",
        "SurfaceFeedbackPlanning",
    },
}
IMPORTS = re.compile(
    r"^[ \t]*(?:(?:@\w+(?:\([^()\n]*\))?|public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:struct|enum|class|protocol|func|var|let|typealias)\s+)?(\w+)",
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
    for name, value in re.findall(r"\b(\w+)\s*:\s*((?:[A-Z]\w*\s*\.\s*)*[A-Z]\w*)", code):
        bindings[name].add(value)
    return tokens, declarations, members, bindings


def expression_context_prefix(prefix):
    """Peel ordinary throwing/await and grouping prefixes before inferring an initializer."""
    while True:
        wrapper = re.search(r"(?:\btry\s*[!?]?|\bawait|\()\s*$", prefix)
        if wrapper is None:
            return prefix
        prefix = prefix[: wrapper.start()]


def nominal_scope_at(code, position):
    """The nearest lexically declared nominal, including extensions and nested types."""
    prefix = code[:position]
    scopes, boundary = [], 0
    for token in TOKENS.finditer(prefix):
        if token.group() == "{":
            header = prefix[boundary : token.start()]
            declared = [
                match.group(1)
                for match in re.finditer(r"\b(?:struct|class|enum|actor|extension|protocol)\s+((?:\w+\.)*\w+)", header)
                if match.group(1) not in {"func", "var", "let"}
            ]
            scopes.append(declared[-1] if declared else scopes[-1] if scopes else None)
            boundary = token.end()
        elif token.group() == "}":
            if scopes:
                scopes.pop()
            boundary = token.end()
        elif token.group() == ";":
            boundary = token.end()
    return scopes[-1] if scopes else None


def contextual_constructor_type(code, position, resolve):
    """Resolve ordinary typed bindings, assignments, computed values and explicit returns."""
    prefix = expression_context_prefix(code[:position])
    statement = re.split(r"[{};]", prefix)[-1]
    binding = re.search(r"\b(?:let|var)\s+\w+\s*:\s*((?:\w+\s*\.\s*)*\w+)\s*[?!]?\s*=\s*$", statement)
    if binding:
        return resolve(binding.group(1))
    assignment = re.search(r"\b(\w+)\s*=\s*$", statement)
    if assignment:
        annotations = re.findall(r"\b" + re.escape(assignment.group(1)) + r"\s*:\s*((?:\w+\s*\.\s*)*\w+)", prefix)
        if annotations:
            candidate = resolve(annotations[-1])
            if candidate:
                return candidate
    # A return's expected type belongs to its lexical function/computed-property scope,
    # and continues through ordinary control blocks. An unrelated closure clears it.
    scopes = []
    boundary = 0
    for token in TOKENS.finditer(prefix):
        if token.group() == "{":
            header = prefix[boundary : token.start()]
            parent = scopes[-1] if scopes else None
            result = re.search(r"->\s*((?:\w+\s*\.\s*)*\w+)\s*[?!]?\s*(?:=\s*)?$", header)
            property_type = re.search(r"\bvar\s+\w+\s*:\s*((?:\w+\s*\.\s*)*\w+)\s*[?!]?\s*$", header)
            if result:
                expected = resolve(result.group(1))
            elif property_type:
                expected = resolve(property_type.group(1))
            elif re.search(r"\b(?:if|else|switch|do|catch|for|while|guard|get)\b[^{};]*$", header):
                expected = parent
            else:
                expected = None
            scopes.append(expected)
            boundary = token.end()
        elif token.group() == "}":
            if scopes:
                scopes.pop()
            boundary = token.end()
        elif token.group() == ";":
            boundary = token.end()
    previous = TOKENS.findall(prefix)
    if previous and previous[-1] in {"return", "{", ":", "?"}:
        return scopes[-1] if scopes else None
    return None


def constructor_errors(path, code, policy, alias_definitions, visible_targets, external_imports):
    if not policy:
        return []
    source_target = path.split("/")[1]

    def resolve(name, target=source_target, externals=external_imports, visited=frozenset(), nominal=None):
        parts = re.sub(r"\s+", "", name).split(".")
        if parts and parts[0] in {"Self", "self"}:
            if nominal is None:
                return None
            parts = nominal.split(".") + parts[1:]
        while len(parts) > 1 and parts[-1] in {"init", "self", "Type"}:
            parts.pop()
        if not parts or parts[0] in externals:
            return None
        if len(parts) > 1 and parts[0] in visible_targets:
            target = parts[0]
        leaf = parts[-1]
        key = (target, leaf)
        if key in visited:
            return None
        if leaf in policy:
            return leaf
        candidates = [item for item in alias_definitions if item[0] == target and item[1] == leaf]
        if not candidates:
            candidates = [item for item in alias_definitions if item[0] in visible_targets and item[1] == leaf]
        if len(candidates) != 1:
            return None
        alias = candidates[0]
        return resolve(alias[2], target=alias[0], externals=alias[3], visited=visited | {key}, nominal=nominal)

    errors = []

    def validate(type_name, opening):
        if type_name and not re.match(r"\s*" + re.escape(policy[type_name]) + r"\s*:", code[opening:]):
            errors.append(f"Runtime construction bypasses validated entry point: {path} -> {type_name}")

    # Includes ordinary calls, module qualification, plain aliases and explicit metatypes.
    for match in re.finditer(r"\b((?:[A-Za-z_]\w*\s*\.\s*)*[A-Za-z_]\w*)\s*\(", code):
        name = match.group(1)
        scope = nominal_scope_at(code, match.start()) if name.split(".")[0].strip() in {"Self", "self"} else None
        validate(resolve(name, nominal=scope), match.end())
    # A leading-dot initializer gets its type from an explicit local/return context.
    for match in re.finditer(r"(?<![\w.])\.\s*init\s*\(", code):
        scope = nominal_scope_at(code, match.start()) if re.search(r"\bSelf\b", code) else None
        validate(
            contextual_constructor_type(code, match.start(), lambda name: resolve(name, nominal=scope)), match.end()
        )
    return errors


def qualification_root(tokens, index):
    while index >= 2 and tokens[index - 1] == "." and tokens[index - 2].isidentifier():
        index -= 2
    return tokens[index]


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
            name = target["name"]
            if name == "XTouchFeedbackTestSupport":
                expected_settings = [
                    {
                        "condition": {"config": "debug", "platformNames": []},
                        "kind": {"unsafeFlags": {"_0": ["-O", "-assert-config", "Debug"]}},
                        "tool": "swift",
                    }
                ]
                if (
                    target.get("type") != "regular"
                    or target.get("path") != "Tests/XTouchFeedbackTestSupport"
                    or target_dependencies(target)
                    != {
                        "XTouchCompactCore",
                        "SurfaceFeedbackPlanning",
                        "SurfaceDeviceContracts",
                        "SurfaceDeviceConformance",
                    }
                ):
                    errors.append("Invalid test-support target boundary")
                if target.get("settings") != expected_settings:
                    errors.append("Invalid test-support Debug assertion-preserving optimization")
                continue
            if any("unsafeFlags" in setting.get("kind", {}) for setting in target.get("settings", [])):
                errors.append("Test-support optimization escaped its target: " + name)
            if target.get("type") == "test":
                continue
            if "XTouchFeedbackTestSupport" in target_dependencies(target):
                errors.append("Test-support module in production target: " + name)
            if name not in targets:
                errors.append("Unclassified production module: " + name)
                continue
            if "SurfaceDeviceConformance" in target_dependencies(target):
                errors.append("Test-only module in production target: " + name + " -> SurfaceDeviceConformance")
            extra = target_dependencies(target) - set(targets[name]["dependencies"])
            if extra:
                errors.append("Forbidden module dependencies: " + name + " -> " + ",".join(sorted(extra)))
    if package is not None:
        for target in package["targets"]:
            if (
                target.get("type") == "test"
                and "XTouchFeedbackTestSupport" in target_dependencies(target)
                and target["name"] not in {"XTouchCompactCoreTests", "XTouchCompactAppTests"}
            ):
                errors.append("Unexpected test-support consumer: " + target["name"])
        for product in package.get("products", []):
            if "XTouchFeedbackTestSupport" in product.get("targets", []):
                errors.append("Test-support module exposed as product")
    parsed, declarations, members, member_owners = {}, defaultdict(set), defaultdict(set), defaultdict(set)
    for path in sorted(actual & roles.keys()):
        if roles[path] not in ROLE_EDGES:
            continue
        code = swift_code((root / path).read_text())
        if "XTouchFeedbackTestSupport" in IMPORTS.findall(code):
            errors.append("Test-support module in production source: " + path)
        if "SurfaceDeviceConformance" in IMPORTS.findall(code):
            errors.append("Test-only module in production source: " + path + " -> SurfaceDeviceConformance")
        parsed[path] = (code, *source_symbols(code))
        for name in parsed[path][2]:
            declarations[name].add(path)
        for owner, name, is_extension in parsed[path][3]:
            members[(owner, name)].add(path)
            if is_extension:
                member_owners[name].add(owner)

    alias_definitions = []
    for source_path, (code, *_rest) in parsed.items():
        externals = frozenset(IMPORTS.findall(code)) - targets.keys()
        for name, value in re.findall(r"\btypealias\s+(\w+)\s*=\s*((?:\w+\s*\.\s*)*\w+)", code):
            alias_definitions.append((source_path.split("/")[1], name, value, externals))

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

        external_imports = set(imports) - targets.keys()
        if role == "runtime":
            errors += constructor_errors(
                path,
                code,
                manifest.get("validated_runtime_constructors", {}),
                alias_definitions,
                visible_targets,
                external_imports,
            )
        for index, token in enumerate(tokens):
            if token in declarations:
                prefix = tokens[index - 2] if index >= 2 and tokens[index - 1] == "." else None
                # A qualified external SDK type is not a coincidentally named host type.
                if qualification_root(tokens, index) not in external_imports:
                    destinations = (
                        {destination for destination in declarations[token] if destination.split("/")[1] == prefix}
                        if prefix in targets
                        else {path}
                        if token in own_types
                        else visible(declarations[token])
                    )
                    for destination in destinations:
                        reference(path, destination, token)
            if (
                index + 2 < len(tokens)
                and tokens[index + 1] == "."
                and tokens[index + 2].isidentifier()
                and qualification_root(tokens, index) not in external_imports
            ):
                member = tokens[index + 2]
                root_qualifier = qualification_root(tokens, index)
                owners = (
                    {(token, root_qualifier if root_qualifier in targets else None)} if token in declarations else set()
                )
                for annotated in bindings.get(token, set()):
                    parts = re.sub(r"\s+", "", annotated).split(".")
                    if parts[0] not in external_imports:
                        owners.add((parts[-1], parts[0] if len(parts) > 1 and parts[0] in targets else None))
                for owner, module in owners:
                    for destination in visible(members.get((owner, member), set())):
                        if module is None or destination.split("/")[1] == module:
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


OWNED_FILES = tuple(
    "Sources/XTouchSurfaceHardware/" + name
    for name in ("OwnedRehearsalSteps.swift", "OwnedVirtualHardwareMIDI.swift", "OwnedVirtualMIDISystem.swift")
)
OWNED_FORBIDDEN = {
    "CoreHardwareMIDI",
    "MIDIGetNumberOfSources",
    "MIDIGetNumberOfDestinations",
    "MIDIGetSource",
    "MIDIGetDestination",
    "MIDIObjectFindByUniqueID",
    "MIDIThruConnectionCreate",
    "MIDIDeviceCreate",
}


def check_owned_virtual(root):
    errors = []
    for name in OWNED_FILES:
        path = Path(root) / name
        if not path.is_file():
            errors.append(name + ": missing owned-only boundary source")
            continue
        code = swift_code(path.read_text())
        for match in re.finditer(r"\b[A-Za-z_][A-Za-z_0-9]*\b", code):
            if match.group() in OWNED_FORBIDDEN:
                errors.append(
                    f"{name}:{code[: match.start()].count(chr(10)) + 1}: forbidden owned-only API {match.group()}"
                )
        for match in re.finditer(r"\bTask\s*(?:\.\s*detached\s*)?[({]|\.\s*async(?:After)?\s*[({]", code):
            errors.append(
                f"{name}:{code[: match.start()].count(chr(10)) + 1}: unbounded asynchronous hop in owned-only boundary"
            )
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.root / "configs/host_layers.json").read_text())
    command = ["swift", "package", "dump-package"]
    if args.scratch_path is not None:
        from configs.build_paths import build_path

        if not str(args.scratch_path).startswith("build/"):
            raise ValueError("Explicit scratch must be under build/")
        scratch = build_path(args.root, str(args.scratch_path.relative_to("build")))
        command = ["swift", "package", "--scratch-path", str(scratch), "--manifest-cache", "local", "dump-package"]
    package = json.loads(subprocess.check_output(command, cwd=args.root))
    report = check_tree(args.root, manifest, package)
    report["errors"].extend(check_owned_virtual(args.root))
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "edges"}, indent=2))
    raise SystemExit(bool(report["errors"]))


if __name__ == "__main__":
    main()
