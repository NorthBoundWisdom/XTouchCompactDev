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


def build(configuration: str) -> Path:
    settings = load_app_build_settings(REPO_ROOT)
    for relative in ("swiftpm", f"app/{configuration}/{PRODUCT}.app", "icons/AppIcon.iconset", "icons/AppIcon.png"):
        build_path(REPO_ROOT, relative)
    options = ["swift", "build", "--build-path", SWIFTPM_ROOT, "--jobs", "2", "--configuration", configuration]
    run([*options, "--product", PRODUCT])
    executable = Path(run([*options, "--show-bin-path"], capture=True)) / PRODUCT
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
    build_path(REPO_ROOT, str((resources / "AppIcon.icns").relative_to(BUILD_ROOT)))
    run(["iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns"])
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


def package() -> Path:
    bundle = build("release")
    settings = load_app_build_settings(REPO_ROOT)
    destination = build_path(REPO_ROOT, "package")
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (
        f"{PRODUCT}_v{settings['MARKETING_VERSION']}_{settings['ARCHIVE_ID']}_macOS_{platform.machine()}_ad-hoc.zip"
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
    smoke = run([bundle / "Contents/MacOS" / PRODUCT, "--startup-smoke"], capture=True, timeout=30)
    validate_smoke(smoke)
    print(smoke)
    print(f"Packaged {archive.relative_to(REPO_ROOT)} (local ad-hoc signature; not notarized)")
    return archive


def validate_smoke(output: str) -> None:
    for line in output.splitlines():
        try:
            marker = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            isinstance(marker, dict)
            and marker.get("type") == "xtouch.native_startup"
            and marker.get("hardwareAccessed") is False
        ):
            return
    raise ValueError("Native startup smoke marker is missing or invalid.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "core", "run", "test", "package"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args(argv)
    if args.action not in {"core", "test"} and sys.platform != "darwin":
        parser.error("App build/run/package requires macOS 14+ and a Swift 6 toolchain.")
    with use_build_environment(REPO_ROOT):
        ensure_dependency(REPO_ROOT)
        if args.action == "test":
            run(["swift", "test", "--build-path", SWIFTPM_ROOT, "--jobs", "2"])
        elif args.action == "core":
            run(
                [
                    "swift",
                    "build",
                    "--build-path",
                    SWIFTPM_ROOT,
                    "--jobs",
                    "2",
                    "--target",
                    "XTouchCompactCore",
                    "--configuration",
                    args.configuration,
                ]
            )
        elif args.action == "package":
            package()
        else:
            bundle = build(args.configuration)
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
