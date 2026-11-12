"""Real independent publishers and fail-closed index/directory replacement."""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from configs import delivery_index

ROOT = Path(__file__).resolve().parents[2]
COMMIT = "a" * 40


def stage_at(root, name, commit=COMMIT, payload="original"):
    stage = root / name
    stage.mkdir()
    (stage / "payload").write_text(payload)
    manifest = {
        "source_commit": commit,
        "surface_control_contract": "1.3",
        "surface_control_sdk": "1.3.0",
        "surface_plugins_revision": "b" * 40,
        "profile_id": "test.profile",
        "profile_version": "1.3",
        "files_sha256": {"payload": hashlib.sha256(payload.encode()).hexdigest()},
    }
    (stage / "manifest.json").write_text(json.dumps(manifest))
    return stage


class DeliveryIndexTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_rebuild_replaces_key_and_preserves_other_host(self):
        output = delivery_index.publish(stage_at(self.root, ".first"), self.root, "xtouch")
        delivery_index.publish(stage_at(self.root, ".other"), self.root, "bcr")
        delivery_index.publish(stage_at(self.root, ".replacement", payload="rebuilt"), self.root, "xtouch")
        index = delivery_index.read_index(self.root)
        self.assertEqual(len(index["deliveries"]), 2)
        self.assertEqual([row["host"] for row in index["deliveries"]], ["bcr", "xtouch"])
        self.assertEqual((output / "payload").read_text(), "rebuilt")
        row = index["deliveries"][1]
        self.assertEqual(row["path"], "xtouch-surface-1.3-aaaaaaa")
        self.assertEqual(row["manifest_sha256"], hashlib.sha256((output / "manifest.json").read_bytes()).hexdigest())
        self.assertFalse((self.root / ".index.lock").exists())
        self.assertEqual(
            sorted(p.name for p in self.root.iterdir()), ["INDEX.json", "bcr-surface-1.3-aaaaaaa", output.name]
        )

    def test_two_independent_processes_preserve_both_publications(self):
        stages = [stage_at(self.root, ".one"), stage_at(self.root, ".two")]
        script = "from configs.delivery_index import publish; import sys; publish(sys.argv[1],sys.argv[2],sys.argv[3])"
        processes = [
            subprocess.Popen(
                [sys.executable, "-B", "-c", script, str(stage), str(self.root), host],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for stage, host in zip(stages, ("xtouch", "bcr"), strict=True)
        ]
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertEqual({row["host"] for row in delivery_index.read_index(self.root)["deliveries"]}, {"xtouch", "bcr"})

    def test_index_commit_failure_restores_previous_directory_and_index(self):
        output = delivery_index.publish(stage_at(self.root, ".old"), self.root, "xtouch")
        old_index = (self.root / "INDEX.json").read_bytes()
        replacement = stage_at(self.root, ".new", payload="new")
        with patch.object(delivery_index.os, "replace", side_effect=OSError("injected index failure")):
            with self.assertRaisesRegex(OSError, "injected"):
                delivery_index.publish(replacement, self.root, "xtouch")
        self.assertEqual((output / "payload").read_text(), "original")
        self.assertEqual((replacement / "payload").read_text(), "new")
        self.assertEqual((self.root / "INDEX.json").read_bytes(), old_index)
        self.assertFalse((self.root / ".index.lock").exists())

    def test_rollback_io_failure_preserves_old_backup_and_reports_its_path(self):
        delivery_index.publish(stage_at(self.root, ".old"), self.root, "xtouch")
        old_index = (self.root / "INDEX.json").read_bytes()
        replacement = stage_at(self.root, ".new", payload="new")
        original_rename = Path.rename

        def rename(path, destination):
            if path.name.startswith(".previous-"):
                raise OSError("injected recovery failure")
            return original_rename(path, destination)

        with patch.object(delivery_index.os, "replace", side_effect=OSError("injected index failure")):
            with patch.object(Path, "rename", rename):
                with self.assertRaisesRegex(RuntimeError, "rollback failed") as failure:
                    delivery_index.publish(replacement, self.root, "xtouch")
        backups = list(self.root.glob(".previous-*"))
        self.assertEqual(len(backups), 1)
        self.assertIn(str(backups[0]), str(failure.exception))
        self.assertEqual((backups[0] / "payload").read_text(), "original")
        self.assertEqual((self.root / "INDEX.json").read_bytes(), old_index)

    def test_first_index_failure_does_not_leave_unindexed_directory(self):
        stage = stage_at(self.root, ".new")
        with patch.object(delivery_index.os, "replace", side_effect=OSError("injected index failure")):
            with self.assertRaises(OSError):
                delivery_index.publish(stage, self.root, "xtouch")
        self.assertTrue(stage.is_dir())
        self.assertFalse((self.root / "xtouch-surface-1.3-aaaaaaa").exists())
        self.assertFalse((self.root / "INDEX.json").exists())

    def test_full_commit_collision_never_replaces_existing_directory(self):
        output = delivery_index.publish(stage_at(self.root, ".old"), self.root, "xtouch")
        old_index = (self.root / "INDEX.json").read_bytes()
        for indexed in (True, False):
            with self.subTest(indexed=indexed):
                if not indexed:
                    (self.root / "INDEX.json").unlink()
                replacement = stage_at(self.root, ".new" + str(indexed), commit="a" * 7 + "c" * 33)
                with self.assertRaisesRegex(RuntimeError, "another full commit"):
                    delivery_index.publish(replacement, self.root, "xtouch")
                self.assertEqual((output / "payload").read_text(), "original")
                if indexed:
                    self.assertEqual((self.root / "INDEX.json").read_bytes(), old_index)

    def test_malformed_and_duplicate_indexes_never_publish(self):
        output = delivery_index.publish(stage_at(self.root, ".old"), self.root, "xtouch")
        original = json.loads((self.root / "INDEX.json").read_text())
        documents = [
            "not json",
            '{"schema_version":1,"deliveries":[],"extra":NaN}',
            '{"schema_version":1,"schema_version":1,"deliveries":[]}',
            json.dumps({"schema_version": True, "deliveries": []}),
            json.dumps({"schema_version": 1, "deliveries": original["deliveries"] * 2}),
        ]
        for number, document in enumerate(documents):
            with self.subTest(document=document):
                (self.root / "INDEX.json").write_text(document)
                stage = stage_at(self.root, ".new" + str(number), payload="new")
                with self.assertRaises(RuntimeError):
                    delivery_index.publish(stage, self.root, "xtouch")
                self.assertEqual((self.root / "INDEX.json").read_text(), document)
                self.assertEqual((output / "payload").read_text(), "original")

    def test_foreign_lock_times_out_without_deleting_it(self):
        lock = self.root / ".index.lock"
        lock.mkdir()
        (lock / "owner.json").write_text("foreign owner")
        with self.assertRaisesRegex(RuntimeError, "locked"):
            delivery_index.publish(stage_at(self.root, ".new"), self.root, "xtouch", timeout=0.02)
        self.assertEqual((lock / "owner.json").read_text(), "foreign owner")

    def test_changed_lock_owner_is_not_removed(self):
        with self.assertRaisesRegex(RuntimeError, "ownership changed"):
            with delivery_index.index_lock(self.root):
                (self.root / ".index.lock/owner.json").write_text("replacement token")
        self.assertEqual((self.root / ".index.lock/owner.json").read_text(), "replacement token")

    def test_symlink_index_and_destination_are_refused(self):
        target = self.root / "elsewhere"
        target.write_text('{"schema_version":1,"deliveries":[]}')
        (self.root / "INDEX.json").symlink_to(target)
        stage = stage_at(self.root, ".new")
        with self.assertRaises(RuntimeError):
            delivery_index.publish(stage, self.root, "xtouch")
        (self.root / "INDEX.json").unlink()
        (self.root / "xtouch-surface-1.3-aaaaaaa").symlink_to(stage, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            delivery_index.publish(stage, self.root, "xtouch")
        self.assertTrue(stage.is_dir())
