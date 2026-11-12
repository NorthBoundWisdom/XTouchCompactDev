"""Serialize complete delivery publication and the shared convention-1 index."""

import hashlib
import json
import os
import re
import secrets
import shutil
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

FIELDS = {
    "host",
    "path",
    "manifest_sha256",
    "contract_version",
    "sdk_version",
    "source_commit",
    "surface_plugins_revision",
    "profile_id",
    "profile_version",
    "generated_at",
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError("Duplicate JSON field: " + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("Non-JSON numeric constant: " + value)


def read_json(path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Expected a regular JSON file: " + str(path))
    try:
        return json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=unique_object, parse_constant=reject_constant
        )
    except (ValueError, UnicodeError) as error:
        raise RuntimeError("Malformed JSON: " + str(path)) from error


def delivery_name(host, contract, commit):
    if not re.fullmatch(r"[a-z0-9-]+", host) or not re.fullmatch(r"[0-9]+\.[0-9]+", contract):
        raise RuntimeError("Invalid delivery host or contract")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("Delivery needs a full lowercase commit")
    return host + "-surface-" + contract + "-" + commit[:7]


def entry_key(entry):
    return entry["host"], entry["source_commit"], entry["contract_version"]


def validate_entry(entry):
    if not isinstance(entry, dict) or not FIELDS <= entry.keys():
        raise RuntimeError("Malformed delivery index entry")
    if any(not isinstance(entry[field], str) or not entry[field] for field in FIELDS):
        raise RuntimeError("Delivery index fields must be nonempty strings")
    if entry["path"] != delivery_name(entry["host"], entry["contract_version"], entry["source_commit"]):
        raise RuntimeError("Index path differs from its delivery identity")
    for field, size in (("manifest_sha256", 64), ("surface_plugins_revision", 40)):
        if not re.fullmatch(r"[0-9a-f]{" + str(size) + "}", entry[field]):
            raise RuntimeError("Invalid index digest: " + field)
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", entry["sdk_version"]):
        raise RuntimeError("Invalid SDK version")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z", entry["generated_at"]):
        raise RuntimeError("Index timestamp must use UTC Z")
    try:
        datetime.fromisoformat(entry["generated_at"][:-1] + "+00:00")
    except ValueError as error:
        raise RuntimeError("Invalid index timestamp") from error


def read_index(root):
    path = root / "INDEX.json"
    if not path.exists() and not path.is_symlink():
        return {"schema_version": 1, "deliveries": []}
    index = read_json(path)
    if (
        not isinstance(index, dict)
        or type(index.get("schema_version")) is not int
        or index["schema_version"] != 1
        or not isinstance(index.get("deliveries"), list)
    ):
        raise RuntimeError("Unsupported or malformed delivery index")
    keys, paths = set(), set()
    for entry in index["deliveries"]:
        validate_entry(entry)
        key = entry_key(entry)
        if key in keys or entry["path"] in paths:
            raise RuntimeError("Duplicate delivery index key or path")
        keys.add(key)
        paths.add(entry["path"])
    return index


@contextmanager
def index_lock(root, timeout=10):
    """Never infer stale ownership from age or remove another process's lock."""
    lock = root / ".index.lock"
    deadline = time.monotonic() + timeout
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise RuntimeError("Delivery index is locked: " + str(lock)) from None
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    identity = lock.stat(follow_symlinks=False)
    owner = lock / "owner.json"
    content = json.dumps({"pid": os.getpid(), "token": secrets.token_hex(16)})
    try:
        owner.write_text(content, encoding="utf-8")
        yield
    finally:
        current = lock.stat(follow_symlinks=False) if lock.exists() else None
        if (
            current is None
            or (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino)
            or owner.is_symlink()
            or not owner.is_file()
            or owner.read_text(encoding="utf-8") != content
        ):
            raise RuntimeError("Delivery index lock ownership changed; refusing cleanup")
        owner.unlink()
        lock.rmdir()


def index_entry(host, directory, manifest):
    entry = {
        "host": host,
        "path": delivery_name(host, manifest["surface_control_contract"], manifest["source_commit"]),
        "manifest_sha256": hashlib.sha256((directory / "manifest.json").read_bytes()).hexdigest(),
        "contract_version": manifest["surface_control_contract"],
        "sdk_version": manifest["surface_control_sdk"],
        "source_commit": manifest["source_commit"],
        "surface_plugins_revision": manifest["surface_plugins_revision"],
        "profile_id": manifest["profile_id"],
        "profile_version": manifest["profile_version"],
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }
    validate_entry(entry)
    return entry


def publish(stage, root, host, timeout=10):
    """Publish a complete sibling stage; roll its directory back if index commit fails."""
    stage, root = Path(stage), Path(root)
    manifest = read_json(stage / "manifest.json")
    output = root / delivery_name(host, manifest["surface_control_contract"], manifest["source_commit"])
    entry = index_entry(host, stage, manifest)
    entry["path"] = output.name
    validate_entry(entry)
    with index_lock(root, timeout):
        index = read_index(root)
        for old in index["deliveries"]:
            if old["path"] == output.name and entry_key(old) != entry_key(entry):
                raise RuntimeError("Delivery short-name collision with another full commit")
        if output.exists() or output.is_symlink():
            if output.is_symlink() or not output.is_dir():
                raise RuntimeError("Refusing non-directory delivery destination")
            old_manifest = read_json(output / "manifest.json")
            if (
                old_manifest.get("source_commit") != manifest["source_commit"]
                or old_manifest.get("surface_control_contract") != manifest["surface_control_contract"]
            ):
                raise RuntimeError("Delivery directory belongs to another full commit or contract")
        fd, temporary = tempfile.mkstemp(prefix=".INDEX-", suffix=".json", dir=root)
        backup, published = None, False
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                if output.exists():
                    backup = root / (".previous-" + secrets.token_hex(16))
                    output.rename(backup)
                try:
                    stage.rename(output)
                    published = True
                    # Reread while holding the common lock; preserve every unrelated entry.
                    index = read_index(root)
                    index["deliveries"] = sorted(
                        [old for old in index["deliveries"] if entry_key(old) != entry_key(entry)] + [entry],
                        key=entry_key,
                    )
                    json.dump(index, stream, indent=2, sort_keys=True, allow_nan=False)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                    os.replace(temporary, root / "INDEX.json")
                except BaseException:
                    try:
                        if published:
                            output.rename(stage)
                        if backup is not None:
                            backup.rename(output)
                    except BaseException as recovery_error:
                        raise RuntimeError(
                            "Delivery rollback failed; preserve and inspect previous delivery at " + str(backup)
                        ) from recovery_error
                    raise
        finally:
            Path(temporary).unlink(missing_ok=True)
        if backup is not None:
            shutil.rmtree(backup)
    return output
