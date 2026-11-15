#!/usr/bin/env python3
"""Build an independent software-only delivery with hashes and exact source pins."""

import argparse
import ast
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

try:
    from .delivery_index import publish
except ImportError:  # Direct CLI execution has configs/ on sys.path.
    from delivery_index import publish

ROOT = Path(__file__).resolve().parents[1]
HOST = "xtouch"


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def default_output(root=ROOT):
    """Delivery directory named only after this repository's HEAD, never another host's commit."""
    short = subprocess.check_output(["git", "rev-parse", "--short=7", "HEAD"], cwd=root, text=True).strip()
    return root / "build" / "deliveries" / ("xtouch-surface-simulator-" + short)


SHARED = ROOT / "build/dependencies/SurfacePlugins"
SDK_VERSION = "1.4.0"
CONTRACT_VERSION = "1.3"
SDK_ZIP = "surface-control-sdk-" + SDK_VERSION + ".zip"
TEST_SUPPORT_ZIP = "surface-control-test-support-" + SDK_VERSION + ".zip"
# Published shared files, copied byte for byte from the managed dependency (single source, D19-6).
# integrations/ and clients/python/tests are deliberately not part of a generic delivery.
SHARED_FILES = {
    "surface-control-diagnostic-capture.schema.json": "docs/surface-control-diagnostic-capture.schema.json",
    "surface-control-diagnostics.md": "docs/surface-control-diagnostics.md",
    "control-tools.json": "docs/surface-control-tools.json",
    "surface-control-scenario.schema.json": "docs/surface-control-scenario.schema.json",
    "surface-control-software-v1.json": "fixtures/surface-control-software-v1.json",
    "surface-control-software-v1.1.json": "fixtures/surface-control-software-v1.1.json",
    "surface-control-software-v1.2.json": "fixtures/surface-control-software-v1.2.json",
    "surface-control-software-v1.3.json": "fixtures/surface-control-software-v1.3.json",
    "surface-control.md": "docs/surface-control.md",
    "surface-control-scenarios.md": "docs/surface-control-scenarios.md",
    "surface-control-delivery.md": "docs/surface-control-delivery.md",
    "surface-control-conformance.md": "docs/surface-control-conformance.md",
    "surface-control-conformance-report.schema.json": "docs/surface-control-conformance-report.schema.json",
    "versioning.md": "docs/versioning.md",
    "CHANGELOG.md": "CHANGELOG.md",
    "release-checklist.md": "docs/release-checklist.md",
}
SDK_SOURCE = "clients/python/surface_control/__init__.py"
# Common manifest fields follow SurfacePlugins docs/surface-control-delivery.md.
ARTIFACT = "surface-control-simulator"


def sdk_sources(shared=SHARED):
    """Stable member order and metadata match the other host's SDK archive."""
    python_root = shared / "clients/python"
    return sorted(
        str(path.relative_to(shared))
        for package in (
            "surface_control",
            "surface_conformance",
            "surface_control_diagnostics",
        )
        for path in (python_root / package).rglob("*")
        if path.is_file() and path.suffix in (".py", ".md")
    )


def test_support_sources(shared=SHARED):
    """Separate, explicitly test-only distribution; excluded from runtime imports."""
    return sorted(
        str(path.relative_to(shared))
        for path in (shared / "clients/python/surface_control_testing").rglob("*")
        if path.is_file() and path.suffix in (".py", ".md")
    )


def stage_test_support(stage, shared=SHARED):
    with zipfile.ZipFile(stage / TEST_SUPPORT_ZIP, "w") as support:
        for source in test_support_sources(shared):
            entry = zipfile.ZipInfo(str(Path(source).relative_to("clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            support.writestr(entry, (shared / source).read_bytes())


def sdk_version(source):
    """Read only the explicit module-level string version; never execute shared code."""
    try:
        assignments = [
            statement.value.value
            for statement in ast.parse(source).body
            if isinstance(statement, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "__version__" for target in statement.targets)
            and isinstance(statement.value, ast.Constant)
            and isinstance(statement.value.value, str)
        ]
    except (SyntaxError, UnicodeError) as error:
        raise RuntimeError("Invalid SDK version metadata") from error
    if assignments != [SDK_VERSION]:
        raise RuntimeError("SDK source version differs from the packaged SDK version")
    return assignments[0]


def validate_sdk_archive(stage, shared=SHARED):
    """The archive filename, embedded version and every source byte must agree."""
    sdk_version((shared / SDK_SOURCE).read_bytes())
    if sorted(path.name for path in stage.glob("surface-control-sdk-*.zip")) != [SDK_ZIP]:
        raise RuntimeError("SDK archive filename differs from the packaged SDK version")
    sources = sdk_sources(shared)
    members = [str(Path(source).relative_to("clients/python")) for source in sources]
    with zipfile.ZipFile(stage / SDK_ZIP) as sdk:
        if sdk.namelist() != members:
            raise RuntimeError("SDK archive members differ from the locked SDK sources")
        sdk_version(sdk.read("surface_control/__init__.py"))
        if any(
            sdk.read(member) != (shared / source).read_bytes() for member, source in zip(members, sources, strict=True)
        ):
            raise RuntimeError("SDK archive differs from the locked SDK source bytes")


def stage_shared_files(stage, root=ROOT, shared=SHARED):
    """Copy host files and shared published files into a delivery stage (no binary)."""
    sdk_version((shared / SDK_SOURCE).read_bytes())
    shutil.copy2(root / "LICENSE", stage)
    shutil.copy2(root / "examples/surface_simulator/minimal_consumer.py", stage)
    shutil.copy2(root / "docs/SURFACE_SIMULATOR.md", stage / "README.md")
    shutil.copy2(root / "configs/surface_plugins.lock.json", stage)
    for name, source in SHARED_FILES.items():
        shutil.copy2(shared / source, stage / name)
    shutil.copy2(root / "examples/surface_simulator/conformance-roles.json", stage)
    # Fixed timestamp, mode and full relative member order keep both hosts' zip bytes equal.
    with zipfile.ZipFile(stage / SDK_ZIP, "w") as sdk:
        for source in sdk_sources(shared):
            entry = zipfile.ZipInfo(str(Path(source).relative_to("clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o644 << 16
            sdk.writestr(entry, (shared / source).read_bytes())
    stage_test_support(stage, shared)
    (stage / "examples").mkdir()
    shutil.copy2(root / "Clients/Python/examples/surface_roundtrip.py", stage / "examples" / "surface_roundtrip.py")
    shutil.copy2(root / "examples/surface_simulator/chassis.json", stage / "examples/chassis.json")
    shutil.copy2(root / "examples/surface_simulator/CHASSIS.md", stage / "examples/CHASSIS.md")


def source_provenance(root=ROOT):
    """Record remote base separately from the clean local candidate; never claim a push."""

    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

    ahead = int(git("rev-list", "--count", "origin/main..HEAD"))
    return {
        "source_origin_main": git("rev-parse", "origin/main"),
        "source_ahead": ahead,
        "source_behind": int(git("rev-list", "--count", "HEAD..origin/main")),
        "delivery_status": "local-unpushed-candidate" if ahead else "remote-head-unreleased-candidate",
    }


def write_manifest(stage, source_commit, configuration, root=ROOT, shared=SHARED):
    """Hash every staged file and record exact host/shared revisions and shared source hashes.

    Profile identity and mapping revision are read from the staged `control-contract.json`,
    which is the delivered binary's own `--describe` output for the default configuration.
    """
    validate_sdk_archive(stage, shared)
    discovery = json.loads((stage / "control-contract.json").read_text())["discovery"]
    if discovery["contract_version"] != CONTRACT_VERSION:
        raise RuntimeError("Binary contract version differs from the packaged contract version")
    files = {
        str(path.relative_to(stage)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(stage.rglob("*"))
        if path.is_file()
    }
    revision = json.loads((root / "configs/surface_plugins.lock.json").read_text())["revision"]
    shared_sources = {
        source: hashlib.sha256((shared / source).read_bytes()).hexdigest()
        for source in [*SHARED_FILES.values(), *sdk_sources(shared), *test_support_sources(shared)]
    }
    manifest = {
        "schema_version": 1,
        **source_provenance(root),
        "artifact": ARTIFACT,
        "product": "XTouchSurfaceSimulator",
        "source": "simulation",
        "source_commit": source_commit,
        "source_dirty": False,
        "surface_control_contract": CONTRACT_VERSION,
        "surface_control_sdk": SDK_VERSION,
        "profile_id": discovery["profile"]["id"],
        "profile_version": discovery["profile"]["version"],
        "mapping_revision": discovery["expected"]["mapping_revision"],
        "surface_plugins_revision": revision,
        "surface_plugins_files_sha256": shared_sources,
        "platform": os.uname().sysname,
        "architecture": os.uname().machine,
        "configuration": configuration,
        "files_sha256": files,
        "start_protocol": "token stdin pipe/private file, ready JSON stdout/file, POST /mcp on 127.0.0.1",
        "stop_protocol": "terminate the isolated process; no persistent user state",
        "test_artifacts": [
            {
                "artifact": "surface-control-test-only-hardware-double",
                "qualification": "test-only",
                "path": TEST_SUPPORT_ZIP,
            }
        ],
    }
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def package(output=None, configuration="release", output_root=None):
    if command("git", "status", "--porcelain"):
        raise RuntimeError("Commit the reviewed source before packaging")
    if output_root is not None and output is not None:
        raise RuntimeError("Choose either a delivery root or an explicit output")
    if output_root is None:
        output = Path(output) if output is not None else default_output()
        if output.exists():
            raise RuntimeError("Output already exists; choose a new delivery path")
    parent = Path(output_root) if output_root is not None else output.parent
    subprocess.run(["python3", "configs/surface_plugins_dependency.py", "verify"], cwd=ROOT, check=True)
    scratch = ROOT / "build" / "surface-simulator" / configuration
    subprocess.run(
        [
            "swift",
            "build",
            "--jobs",
            "2",
            "--configuration",
            configuration,
            "--scratch-path",
            str(scratch),
            "--product",
            "XTouchSurfaceSimulator",
        ],
        cwd=ROOT,
        check=True,
    )
    binary_directory = Path(
        command("swift", "build", "--configuration", configuration, "--scratch-path", str(scratch), "--show-bin-path")
    )
    parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".surface-simulator-", dir=parent))
    try:
        shutil.copy2(binary_directory / "XTouchSurfaceSimulator", stage)
        stage_shared_files(stage)
        (stage / "control-contract.json").write_text(
            subprocess.check_output([str(stage / "XTouchSurfaceSimulator"), "--describe"], text=True)
        )
        write_manifest(stage, command("git", "rev-parse", "HEAD"), configuration)
        if output_root is None:
            stage.rename(output)
        else:
            output = publish(stage, parent, HOST)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    destination = parser.add_mutually_exclusive_group()
    destination.add_argument(
        "--output",
        type=Path,
        help="new delivery directory (default: build/deliveries/xtouch-surface-simulator-<HEAD short SHA>)",
    )
    destination.add_argument(
        "--output-root",
        type=Path,
        help="unified root: <host>-surface-<contract>-<SHA7> and atomic INDEX.json (e.g. ../deliveries)",
    )
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    output = args.output.resolve() if args.output else None
    output_root = args.output_root.resolve() if args.output_root else None
    print(package(output, args.configuration, output_root))


if __name__ == "__main__":
    main()
