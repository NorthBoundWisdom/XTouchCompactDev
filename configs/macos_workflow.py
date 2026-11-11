#!/usr/bin/env python3
"""Build/run a local macOS app bundle, test Swift, or package an ad-hoc ZIP."""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings
from configs.build_environment import use_build_environment

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
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    (bundle / "Contents/PkgInfo").write_bytes(b"APPL????")
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", bundle])
    verify_bundle(bundle)
    print(f"Built {bundle.relative_to(REPO_ROOT)}")
    return bundle


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
        relative = f"{language}.lproj/Localizable.strings"
        if not any((root / relative).is_file() for root in (localization, localization / "Contents/Resources")):
            raise ValueError(f"Missing packaged language: {language}")
    run(["codesign", "--verify", "--deep", "--strict", bundle])


def package() -> Path:
    bundle = build("release")
    settings = load_app_build_settings(REPO_ROOT)
    destination = BUILD_ROOT / "package"
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (
        f"{PRODUCT}_v{settings['MARKETING_VERSION']}_{settings['ARCHIVE_ID']}_macOS_{platform.machine()}_ad-hoc.zip"
    )
    archive.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archive])
    checksum = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    digest = checksum.hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
    dmg = archive.with_suffix(".dmg")
    run(["hdiutil", "create", "-volname", "XTouch Compact", "-srcfolder", bundle.parent, "-ov", "-format", "UDZO", dmg])
    checksum = hashlib.sha256()
    with dmg.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    dmg.with_suffix(".dmg.sha256").write_text(f"{checksum.hexdigest()}  {dmg.name}\n")
    smoke = run([bundle / "Contents/MacOS" / PRODUCT, "--startup-smoke"], capture=True, timeout=30)
    if '"hardwareAccessed":false' not in smoke or '"type":"xtouch.native_startup"' not in smoke:
        raise ValueError("Native startup smoke marker is missing.")
    print(smoke)
    print(f"Packaged {archive.relative_to(REPO_ROOT)} (local ad-hoc signature; not notarized)")
    return archive


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "core", "run", "test", "package"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args(argv)
    if args.action not in {"core", "test"} and sys.platform != "darwin":
        parser.error("App build/run/package requires macOS 14+ and a Swift 6 toolchain.")
    with use_build_environment(REPO_ROOT):
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
