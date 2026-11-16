#!/usr/bin/env python3
"""Build/run a local macOS app bundle, test Swift, or package an ad-hoc ZIP."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings
from configs.build_environment import use_build_environment
from configs.build_paths import build_path
from configs.surface_plugins_dependency import ensure_dependency

PRODUCT = "XTouchCompactApp"
BUNDLE_ID = "dev.xtouchcompact.app"
BUILD_ROOT = REPO_ROOT / "build"
SWIFTPM_ROOT = BUILD_ROOT / "swiftpm"


def run(command: list[str | Path], *, capture: bool = False, timeout: int | None = None) -> str:
    argv = [str(part) for part in command]
    print(">>", " ".join(argv), flush=True)
    result = subprocess.run(
        argv, cwd=REPO_ROOT, text=True, stdout=subprocess.PIPE if capture else None, check=True, timeout=timeout
    )
    return result.stdout.strip() if capture else ""


def architectures(architecture: str) -> tuple[str, ...]:
    if architecture == "universal":
        return ("arm64", "x86_64")
    result = platform.machine() if architecture == "native" else architecture
    if result not in {"arm64", "x86_64"}:
        raise ValueError("Unsupported macOS architecture")
    return (result,)


def swift_executable(configuration: str, architecture: str, prebuilt_slices: Path | None = None) -> Path:
    binaries = []
    for arch in architectures(architecture):
        if prebuilt_slices is not None:
            if configuration != "release" or architecture != "universal":
                raise ValueError("Prebuilt slices require universal release packaging")
            binary = verify_release_slice(prebuilt_slices, arch)
        else:
            root = SWIFTPM_ROOT if architecture == "native" else SWIFTPM_ROOT / arch
            build_path(REPO_ROOT, str(root.relative_to(BUILD_ROOT)))
            options = ["swift", "build", "--build-path", root, "--configuration", configuration]
            if architecture != "native":
                options += ["--triple", f"{arch}-apple-macosx14.0"]
            run([*options, "--product", PRODUCT])
            binary = Path(run([*options, "--show-bin-path"], capture=True)) / PRODUCT
        if not binary.is_file():
            raise ValueError("Swift build did not produce the app executable")
        binaries.append(binary)
    if len(binaries) == 1:
        return binaries[0]
    destination = build_path(REPO_ROOT, f"swiftpm/universal/{configuration}")
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / PRODUCT
    run(["lipo", "-create", *binaries, "-output", output])
    bundle_name = "XTouchCompactDev_XTouchCompactLocalization.bundle"
    resource = destination / bundle_name
    build_path(REPO_ROOT, str(resource.relative_to(BUILD_ROOT)))
    if resource.exists():
        shutil.rmtree(resource)
    shutil.copytree(binaries[0].parent / bundle_name, resource)
    return output


def slice_identity(architecture: str) -> dict:
    metadata = source_metadata()
    if metadata.get("XTouchSourceTreeDirty") is not False or not metadata.get("XTouchSourceRevision"):
        raise ValueError("Release slices require a clean committed source")
    return {
        "schema_version": 1,
        "architecture": architecture,
        "configuration": "release",
        "commit": metadata["XTouchSourceRevision"],
        "surface_plugins_revision": json.loads((REPO_ROOT / "configs/surface_plugins.lock.json").read_text())[
            "revision"
        ],
    }


def slice_hashes(directory: Path) -> dict:
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError("Release slice must not contain symlinks")
        if path.is_file() and path != directory / "slice.json":
            result[str(path.relative_to(directory))] = sha256(path)
    return result


def stage_release_slice(architecture: str) -> Path:
    if architecture not in {"arm64", "x86_64"}:
        raise ValueError("Expected one release architecture")
    options = [
        "swift",
        "build",
        "--build-path",
        SWIFTPM_ROOT / architecture,
        "--configuration",
        "release",
        "--triple",
        f"{architecture}-apple-macosx14.0",
    ]
    source = Path(run([*options, "--show-bin-path"], capture=True))
    destination = build_path(REPO_ROOT, f"native-slices/{architecture}")
    identity = slice_identity(architecture)
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copy2(source / PRODUCT, destination / PRODUCT)
    resources = "XTouchCompactDev_XTouchCompactLocalization.bundle"
    shutil.copytree(source / resources, destination / resources)
    if architecture == "x86_64":
        shutil.copy2(prepare_icon(), destination / "AppIcon.icns")
    (destination / "slice.json").write_text(
        json.dumps({**identity, "files_sha256": slice_hashes(destination)}, indent=2) + "\n"
    )
    verify_release_slice(destination.parent, architecture)
    return destination


def verify_release_slice(directory: Path, architecture: str) -> Path:
    directory = directory.absolute()
    directory = build_path(REPO_ROOT, str(directory.relative_to(BUILD_ROOT))) / architecture
    # Validate every component, including the selected architecture directory.
    build_path(REPO_ROOT, str(directory.relative_to(BUILD_ROOT)))
    record = json.loads((directory / "slice.json").read_text())
    identity = slice_identity(architecture)
    if {key: record.get(key) for key in identity} != identity or record.get("files_sha256") != slice_hashes(directory):
        raise ValueError("Release slice source, dependency, architecture or checksum mismatch")
    executable = directory / PRODUCT
    if run(["lipo", "-archs", executable], capture=True).split() != [architecture]:
        raise ValueError("Release slice architecture mismatch")
    if not (directory / "XTouchCompactDev_XTouchCompactLocalization.bundle").is_dir():
        raise ValueError("Missing release slice localization")
    return executable


def prepare_icon() -> Path:
    output = build_path(REPO_ROOT, "icons/AppIcon.icns")
    marker = build_path(REPO_ROOT, "icons/source.sha256")
    digest = sha256(REPO_ROOT / "configs/app_icon.swift")
    if output.is_file() and marker.is_file() and marker.read_text() == digest:
        return output
    iconroot = BUILD_ROOT / "icons"
    run(["swift", REPO_ROOT / "configs/app_icon.swift", iconroot])
    iconset = iconroot / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = str(size * scale)
            suffix = "@2x" if scale == 2 else ""
            build_path(REPO_ROOT, f"icons/AppIcon.iconset/icon_{size}x{size}{suffix}.png")
            run(
                [
                    "sips",
                    "-z",
                    pixels,
                    pixels,
                    iconroot / "AppIcon.png",
                    "--out",
                    iconset / f"icon_{size}x{size}{suffix}.png",
                ],
                capture=True,
            )
    run(["iconutil", "-c", "icns", iconset, "-o", output])
    marker.write_text(digest)
    return output


def build(configuration: str, architecture: str = "native", prebuilt_slices: Path | None = None) -> Path:
    settings = load_app_build_settings(REPO_ROOT)
    for relative in ("swiftpm", f"app/{configuration}/{PRODUCT}.app", "icons/AppIcon.iconset", "icons/AppIcon.png"):
        build_path(REPO_ROOT, relative)
    executable = swift_executable(configuration, architecture, prebuilt_slices)
    if configuration == "release":
        verify_release_test_hooks(executable)
    bundle = BUILD_ROOT / "app" / configuration / f"{PRODUCT}.app"
    if bundle.is_symlink():
        raise ValueError(f"Refusing to overwrite a symlinked app bundle: {bundle}")
    if bundle.exists():
        shutil.rmtree(bundle)
    macos = bundle / "Contents/MacOS"
    macos.mkdir(parents=True)
    shutil.copy2(executable, macos / PRODUCT)
    (macos / PRODUCT).chmod(0o755)
    resources = bundle / "Contents/Resources"
    resources.mkdir()
    localization = executable.parent / "XTouchCompactDev_XTouchCompactLocalization.bundle"
    if not localization.is_dir():
        raise ValueError(f"Missing localization resources: {localization}")
    shutil.copytree(localization, resources / localization.name)
    icon = prebuilt_slices / "x86_64/AppIcon.icns" if prebuilt_slices is not None else prepare_icon()
    shutil.copy2(icon, resources / "AppIcon.icns")
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["en", "zh-Hans", "zh-Hant"],
        "CFBundleDisplayName": "XTouch Compact",
        "CFBundleExecutable": PRODUCT,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleIconFile": "AppIcon.icns",
        "CFBundleName": "XTouch Compact",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": settings["MARKETING_VERSION"],
        "CFBundleVersion": settings["ARCHIVE_ID"],
        "LSApplicationCategoryType": "public.app-category.music",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    info.update(source_metadata())
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    (bundle / "Contents/PkgInfo").write_bytes(b"APPL????")
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", bundle])
    verify_bundle(bundle)
    print(f"Built {bundle.relative_to(REPO_ROOT)}")
    return bundle


def source_metadata() -> dict[str, str | bool]:
    """Unknown build provenance stays absent instead of inventing a clean revision."""
    try:
        revision = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True, timeout=5, check=True
        ).stdout.strip()
        if not re.fullmatch(r"[a-f0-9]{40,64}", revision):
            return {}
        status = subprocess.run(
            ["git", "status", "--porcelain"], cwd=REPO_ROOT, capture_output=True, text=True, timeout=5, check=True
        ).stdout
        return {"XTouchSourceRevision": revision, "XTouchSourceTreeDirty": bool(status.strip())}
    except (OSError, subprocess.SubprocessError):
        return {}


RELEASE_FORBIDDEN_HOOKS = (
    "integrationAgentWrite",
    "integrationPhysicalLayer",
    "integrationFlushValues",
    "integrationCapture",
    "integrationAdvance",
    "readIntegrationState",
    "integrationSummary",
    "integrationMotorLedger",
    "integration_read_state",
    "OffscreenContext",
    "OffscreenAcceptanceView",
    "fixture.capture",
)


def verify_release_test_hooks(executable: Path) -> None:
    data = executable.read_bytes()
    found = [name for name in RELEASE_FORBIDDEN_HOOKS if name.encode() in data]
    if found:
        raise ValueError("Release executable contains Debug acceptance hooks: " + ", ".join(found))


def verify_bundle(bundle: Path) -> None:
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if (
        info.get("CFBundleIdentifier") != BUNDLE_ID
        or info.get("CFBundleExecutable") != PRODUCT
        or info.get("LSMinimumSystemVersion") != "14.0"
    ):
        raise ValueError("Unexpected app bundle metadata.")
    if not os.access(bundle / "Contents/MacOS" / PRODUCT, os.X_OK):
        raise ValueError("Missing app executable.")
    for language in ("en", "zh-Hans", "zh-Hant"):
        localization = bundle / "Contents/Resources/XTouchCompactDev_XTouchCompactLocalization.bundle"
        if not any(
            child.name.casefold() == f"{language}.lproj".casefold() and (child / "Localizable.strings").is_file()
            for root in (localization, localization / "Contents/Resources")
            if root.is_dir()
            for child in root.iterdir()
        ):
            raise ValueError(f"Missing packaged language: {language}")
    run(["codesign", "--verify", "--deep", "--strict", bundle])


def package(architecture: str = "native", prebuilt_slices: Path | None = None) -> Path:
    bundle = build("release", architecture, prebuilt_slices)
    settings = load_app_build_settings(REPO_ROOT)
    destination = build_path(REPO_ROOT, "package")
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (
        f"{PRODUCT}_v{settings['MARKETING_VERSION']}_{settings['ARCHIVE_ID']}_macOS_{'universal' if architecture == 'universal' else architectures(architecture)[0]}_ad-hoc.zip"
    )
    for artifact in (
        archive,
        archive.with_suffix(".zip.sha256"),
        archive.with_suffix(".dmg"),
        archive.with_suffix(".dmg.sha256"),
    ):
        build_path(REPO_ROOT, str(artifact.relative_to(BUILD_ROOT)))
    archive.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archive])
    checksum = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    digest = checksum.hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
    dmg = archive.with_suffix(".dmg")
    run(["hdiutil", "create", "-volname", "XTouch Compact", "-srcfolder", bundle, "-ov", "-format", "UDZO", dmg])
    checksum = hashlib.sha256()
    with dmg.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    dmg.with_suffix(".dmg.sha256").write_text(f"{checksum.hexdigest()}  {dmg.name}\n")
    write_build_records([archive, dmg], architecture)
    # Verify extracted final assets, never just the pre-archive build directory.
    check_package(archive)
    check_package(dmg)
    print(f"Packaged {archive.relative_to(REPO_ROOT)} (local ad-hoc signature; not notarized)")
    return archive


def sha256(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def write_build_records(assets: list[Path], architecture: str) -> None:
    settings = load_app_build_settings(REPO_ROOT)
    source = source_metadata()
    if set(source) != {"XTouchSourceRevision", "XTouchSourceTreeDirty"}:
        raise ValueError("Cannot record build source provenance")
    lock = json.loads((REPO_ROOT / "configs/surface_plugins.lock.json").read_text())
    swift = run(["swift", "--version"], capture=True)
    for asset in assets:
        record = {
            "schema_version": 1,
            "asset": asset.name,
            "sha256": sha256(asset),
            "version": settings["MARKETING_VERSION"],
            "build": settings["ARCHIVE_ID"],
            "commit": source["XTouchSourceRevision"],
            "dirty": source["XTouchSourceTreeDirty"],
            "architecture": architecture,
            "architectures": list(architectures(architecture)),
            "signature": "ad-hoc",
            "notarized": False,
            "minimum_macos": "14.0",
            "swift": swift,
            "surface_plugins_revision": lock["revision"],
        }
        destination = asset.with_suffix(asset.suffix + ".build.json")
        build_path(REPO_ROOT, str(destination.relative_to(BUILD_ROOT)))
        destination.write_text(json.dumps(record, indent=2) + "\n")


def validate_package_record(
    archive: Path,
    *,
    expected_commit: str | None = None,
    expected_plugins_revision: str | None = None,
    require_clean: bool = False,
) -> dict:
    record = json.loads(archive.with_suffix(archive.suffix + ".build.json").read_text())
    if not isinstance(record, dict):
        raise ValueError("Invalid package record")
    selected = record.get("architecture")
    actual = record.get("architectures")
    if (
        not isinstance(selected, str)
        or selected not in {"native", "arm64", "x86_64", "universal"}
        or not isinstance(actual, list)
        or any(not isinstance(item, str) or item not in {"arm64", "x86_64"} for item in actual)
        or len(actual) != len(set(actual))
        or (selected == "native" and len(actual) != 1)
        or (selected != "native" and set(actual) != set(architectures(selected)))
    ):
        raise ValueError("Invalid architecture record")
    if (
        type(record.get("schema_version")) is not int
        or record.get("schema_version") != 1
        or record.get("asset") != archive.name
        or record.get("sha256") != sha256(archive)
        or record.get("signature") != "ad-hoc"
        or record.get("notarized") is not False
        or type(record.get("dirty")) is not bool
        or not isinstance(record.get("commit"), str)
        or not re.fullmatch(r"[a-f0-9]{40}", record["commit"])
        or not isinstance(record.get("surface_plugins_revision"), str)
        or not re.fullmatch(r"[a-f0-9]{40}", record["surface_plugins_revision"])
        or record.get("minimum_macos") != "14.0"
        or not isinstance(record.get("swift"), str)
        or not record["swift"]
        or not isinstance(record.get("version"), str)
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", record["version"])
        or not isinstance(record.get("build"), str)
        or not re.fullmatch(r"[1-9][0-9]*", record["build"])
    ):
        raise ValueError("Package record provenance or checksum mismatch")
    checksum = archive.with_suffix(archive.suffix + ".sha256").read_text()
    if checksum != f"{record['sha256']}  {archive.name}\n":
        raise ValueError("Package checksum sidecar mismatch")
    if (
        expected_commit is not None
        and record["commit"] != expected_commit
        or expected_plugins_revision is not None
        and record["surface_plugins_revision"] != expected_plugins_revision
        or require_clean
        and record["dirty"]
    ):
        raise ValueError("Package differs from expected clean source/dependency revision")
    return record


def check_package(
    archive: Path,
    *,
    expected_commit: str | None = None,
    expected_plugins_revision: str | None = None,
    require_clean: bool = False,
) -> None:
    archive = archive.resolve()
    record = validate_package_record(
        archive,
        expected_commit=expected_commit,
        expected_plugins_revision=expected_plugins_revision,
        require_clean=require_clean,
    )
    build_path(REPO_ROOT, "package-check")
    BUILD_ROOT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xtouch-package-", dir=BUILD_ROOT) as temporary:
        root = Path(temporary)
        if archive.suffix == ".zip":
            run(["ditto", "-x", "-k", archive, root])
            bundle = root / f"{PRODUCT}.app"
            verify_packaged_payload(bundle, record)
        elif archive.suffix == ".dmg":
            mount = root / "mounted"
            run(["hdiutil", "attach", archive, "-readonly", "-nobrowse", "-mountpoint", mount])
            try:
                bundle = root / f"{PRODUCT}.app"
                run(["ditto", mount / f"{PRODUCT}.app", bundle])
                verify_packaged_payload(bundle, record)
            finally:
                run(["hdiutil", "detach", mount])
        else:
            raise ValueError("Expected a ZIP or DMG")
    print(f"Verified final package {archive.name}")


def verify_packaged_payload(bundle: Path, record: dict) -> None:
    verify_bundle(bundle)
    verify_release_test_hooks(bundle / "Contents/MacOS" / PRODUCT)
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if (
        info.get("CFBundleShortVersionString") != record["version"]
        or info.get("CFBundleVersion") != record["build"]
        or info.get("XTouchSourceRevision") != record["commit"]
        or info.get("XTouchSourceTreeDirty") != record["dirty"]
    ):
        raise ValueError("Packaged bundle metadata differs from build record")
    binary = bundle / "Contents/MacOS" / PRODUCT
    actual = run(["lipo", "-archs", binary], capture=True).split()
    if set(actual) != set(record["architectures"]):
        raise ValueError("Packaged executable architecture mismatch")
    if platform.machine() in actual:
        for mode, flag in [("headless", "--startup-smoke=headless"), ("gui", "--startup-smoke")]:
            output = run([binary, flag], capture=True, timeout=30)
            validate_smoke(output, mode=mode)
            print(output)
    else:
        print("Structural verification passed; native launch requires a matching architecture runner.")


def validate_smoke(output: str, *, mode: str = "gui") -> None:
    if mode not in {"gui", "headless"}:
        raise ValueError("Unknown startup smoke mode")
    for line in output.splitlines():
        try:
            marker = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            isinstance(marker, dict)
            and marker.get("type") == "xtouch.native_startup"
            and marker.get("hardwareAccessed") is False
            and marker.get("mode") == mode
            and marker.get("windowCreated") is (mode == "gui")
            and marker.get("firstFramePresented") is (mode == "gui")
        ):
            return
    raise ValueError("Native startup smoke marker is missing or invalid.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "core", "run", "test", "package", "check-package"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--architecture", choices=("native", "arm64", "x86_64", "universal"), default="native")
    parser.add_argument(
        "--prebuilt-slices",
        type=Path,
        help="Verified release slice artifacts from this exact source/dependency revision",
    )
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args(argv)
    if args.prebuilt_slices is not None and (args.action != "package" or args.architecture != "universal"):
        parser.error("--prebuilt-slices requires package --architecture universal")
    if args.action not in {"core", "test"} and sys.platform != "darwin":
        parser.error("App build/run/package requires macOS 14+ and a Swift 6 toolchain.")
    with use_build_environment(REPO_ROOT):
        if args.action == "check-package":
            if args.archive is None:
                parser.error("check-package requires --archive")
            check_package(args.archive)
            return 0
        # Verified slices already pin the dependency and carry all compiled resources.
        if args.prebuilt_slices is None:
            ensure_dependency(REPO_ROOT)
        if args.action == "test":
            run(["swift", "test", "--build-path", SWIFTPM_ROOT])
        elif args.action == "core":
            run(
                [
                    "swift",
                    "build",
                    "--build-path",
                    SWIFTPM_ROOT,
                    "--target",
                    "XTouchCompactCore",
                    "--configuration",
                    args.configuration,
                ]
            )
        elif args.action == "package":
            package(args.architecture, args.prebuilt_slices)
        else:
            bundle = build(args.configuration, args.architecture)
            if args.action == "run":
                # Replace Python so terminal signals and exit status belong to the app.
                executable = bundle / "Contents/MacOS" / PRODUCT
                os.chdir(REPO_ROOT)
                os.execv(str(executable), [str(executable)])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
