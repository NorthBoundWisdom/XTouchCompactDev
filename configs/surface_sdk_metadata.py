"""Strict package-local SDK metadata. The legacy and current versions are explicit, never guessed."""

import ast
import hashlib
import json
import zipfile
from pathlib import Path

SUPPORTED_SDKS = frozenset({"1.4.0", "1.5.0"})
CURRENT_SDK = "1.5.0"


def source_version(body):
    values = [
        node.value.value
        for node in ast.parse(body).body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "__version__" for target in node.targets)
        and isinstance(node.value, ast.Constant)
        and isinstance(node.value.value, str)
    ]
    if len(values) != 1 or values[0] not in SUPPORTED_SDKS:
        raise ValueError("Unsupported or ambiguous SDK source version")
    return values[0]


def package_sdk(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    version = manifest.get("surface_control_sdk")
    if version not in SUPPORTED_SDKS:
        raise ValueError("Unsupported delivery SDK metadata")
    name = "surface-control-sdk-" + version + ".zip"
    archive = directory / name
    if not archive.is_file() or sorted(p.name for p in directory.glob("surface-control-sdk-*.zip")) != [name]:
        raise ValueError("Delivery SDK archive name is inconsistent")
    if manifest.get("files_sha256", {}).get(name) != hashlib.sha256(archive.read_bytes()).hexdigest():
        raise ValueError("Delivery SDK archive hash is inconsistent")
    with zipfile.ZipFile(archive) as sdk:
        if source_version(sdk.read("surface_control/__init__.py")) != version:
            raise ValueError("Delivery SDK module version is inconsistent")
    return archive, version
