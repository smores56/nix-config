"""Unit tests for the phone pipeline (smores56/sdlc#593).

Covers the decrypt wrapper's password contract, receive-encrypted folder check, atomic
swap, dedupe/size cap and heartbeat batch; the SMS export schema validator; the fork's
manifest/permission checker; and the static config contract asserted by the Nix modules.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).parents[1]
PHONE = REPO / "modules/lib/phone/phone_decrypt.py"
SMS_VALIDATOR = REPO / "mobile/sms-ie/validate-export.py"
VERIFY_MANIFEST = REPO / "mobile/healthconnect-export/verify-manifest.sh"
FIXTURES = REPO / "mobile/healthconnect-export/fixtures"

PATTERNS = {
    "sms": [
        re.compile(r"^messages-[0-9]{4}-[0-9]{2}-[0-9]{2}\.zip$"),
        re.compile(r"^calls-[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$"),
    ],
    "contacts": [re.compile(r"^contacts-[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$")],
    "health": [re.compile(r"^health_[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$")],
}


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_encrypted_folder(folder: Path, folder_id: str = "phone") -> None:
    marker = folder / ".stfolder"
    marker.mkdir(parents=True)
    (marker / "syncthing-encryption_password_token").write_text(
        json.dumps({"FolderID": folder_id, "Token": "dG9rZW4="})
    )
    for name in ("S.syncthing-enc", "H.syncthing-enc"):
        (folder / name / "21").mkdir(parents=True)


def fake_syncthing(path: Path, plaintext: Path, password: str = "pw") -> None:
    path.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        'out=""; folder=""\n'
        'while [ $# -gt 0 ]; do case "$1" in --to) out=$2; shift 2;; *) folder=$1; shift;; esac; done\n'
        f'[ "${{FOLDER_PASSWORD:-}}" = "{password}" ] || {{ echo "bad password" >&2; exit 9; }}\n'
        f'cp -R {plaintext}/. "$out"/\n'
    )
    path.chmod(0o755)


class DecryptContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.decrypt = load(PHONE, "phone_decrypt")

    def tearDown(self):
        self.tmp.cleanup()

    def test_contract_is_staged_into_the_volume_with_0400(self):
        contract = self.root / "contract"
        contract.write_text("s3cret\n")
        staged = self.root / "luks/secrets/password"

        self.assertEqual("s3cret", self.decrypt.stage_password(contract, staged))
        self.assertEqual(0o400, stat.S_IMODE(staged.stat().st_mode))
        self.assertEqual("s3cret\n", staged.read_text())

    def test_missing_password_is_refused(self):
        with self.assertRaises(self.decrypt.PhoneDecryptError) as raised:
            self.decrypt.stage_password(self.root / "absent", self.root / "luks/password")
        self.assertEqual(self.decrypt.EXIT_PASSWORD, raised.exception.code)

    def test_empty_contract_is_refused(self):
        contract = self.root / "contract"
        contract.write_text("\n")
        with self.assertRaises(self.decrypt.PhoneDecryptError) as raised:
            self.decrypt.stage_password(contract, self.root / "luks/password")
        self.assertEqual(self.decrypt.EXIT_CONTRACT, raised.exception.code)

    def test_staged_password_must_be_0400(self):
        staged = self.root / "password"
        staged.write_text("pw")
        staged.chmod(0o644)
        with self.assertRaises(self.decrypt.PhoneDecryptError) as raised:
            self.decrypt.read_password(staged)
        self.assertEqual(self.decrypt.EXIT_CONTRACT, raised.exception.code)

    def test_staged_copy_survives_a_missing_contract(self):
        contract = self.root / "contract"
        contract.write_text("pw")
        staged = self.root / "luks/password"
        self.decrypt.stage_password(contract, staged)
        contract.unlink()
        self.assertEqual("pw", self.decrypt.stage_password(contract, staged))


class ReceiveEncryptedFolderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.decrypt = load(PHONE, "phone_decrypt")

    def tearDown(self):
        self.tmp.cleanup()

    def test_token_identifies_the_folder(self):
        folder = self.root / "phone"
        write_encrypted_folder(folder, "phone")
        self.assertEqual("phone", self.decrypt.folder_id(folder))

    def test_plaintext_folder_is_refused(self):
        folder = self.root / "plain"
        folder.mkdir()
        (folder / "messages.ndjson").write_text("{}\n")
        with self.assertRaises(self.decrypt.PhoneDecryptError) as raised:
            self.decrypt.folder_id(folder)
        self.assertEqual(self.decrypt.EXIT_FOLDER, raised.exception.code)

    def test_receive_encrypted_folder_with_a_plaintext_entry_is_refused(self):
        folder = self.root / "phone"
        write_encrypted_folder(folder)
        (folder / "stray.json").write_text("{}")
        with self.assertRaises(self.decrypt.PhoneDecryptError) as raised:
            self.decrypt.folder_id(folder)
        self.assertEqual(self.decrypt.EXIT_FOLDER, raised.exception.code)


class AtomicSwapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.decrypt = load(PHONE, "phone_decrypt")

    def tearDown(self):
        self.tmp.cleanup()

    def test_exchange_replaces_the_live_tree(self):
        target = self.root / "phone"
        target.mkdir()
        (target / "old").write_text("old")
        stage = self.root / ".phone.stage"
        stage.mkdir()
        (stage / "new").write_text("new")

        self.decrypt.swap_dirs(stage, target)

        self.assertEqual("new", (target / "new").read_text())
        self.assertFalse((target / "old").exists())
        self.assertFalse(stage.exists())

    def test_missing_target_is_created_by_rename(self):
        stage = self.root / ".phone.stage"
        stage.mkdir()
        (stage / "file").write_text("x")
        target = self.root / "phone"
        self.decrypt.swap_dirs(stage, target)
        self.assertEqual("x", (target / "file").read_text())

    def test_fallback_path_is_used_when_exchange_is_unavailable(self):
        target = self.root / "phone"
        target.mkdir()
        (target / "old").write_text("old")
        stage = self.root / ".phone.stage"
        stage.mkdir()
        (stage / "new").write_text("new")

        original = self.decrypt._rename_exchange

        def unavailable(left, right):
            raise OSError(38, "not supported")

        self.decrypt._rename_exchange = unavailable
        try:
            self.decrypt.swap_dirs(stage, target)
        finally:
            self.decrypt._rename_exchange = original

        self.assertEqual("new", (target / "new").read_text())
        self.assertFalse((target / "old").exists())


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.decrypt = load(PHONE, "phone_decrypt")

        self.source = self.root / "encrypted"
        write_encrypted_folder(self.source)
        self.plaintext = self.root / "plaintext"
        (self.plaintext / "sms").mkdir(parents=True)
        (self.plaintext / "health").mkdir()
        (self.plaintext / "sms/messages-2026-11-10.zip").write_bytes(b"zip")
        (self.plaintext / "sms/calls-2026-11-10.json").write_text("[]")
        (self.plaintext / "sms/contacts-2026-11-10.json").write_text("[]")
        (self.plaintext / "health/health_2026-11-10.json").write_text("{}")
        (self.plaintext / "sms/notes.txt").write_text("stray")

        self.syncthing = self.root / "syncthing"
        fake_syncthing(self.syncthing, self.plaintext)

        self.contract = self.root / "contract"
        self.contract.write_text("pw")
        self.staged = self.root / "luks/secrets/password"
        self.target = self.root / "luks/phone"
        self.state = self.root / "luks/phone-state/index.json"
        self.batches = self.root / "luks/phone-state/batches"
        self.heartbeat = self.root / "luks/phone-state/heartbeat.json"
        self.max_bytes = 16 * 1024 * 1024

    def tearDown(self):
        self.tmp.cleanup()

    def run_once(self):
        return self.decrypt.run(
            source=self.source,
            target=self.target,
            contract=self.contract,
            staged=self.staged,
            state_path=self.state,
            batch_dir=self.batches,
            heartbeat_path=self.heartbeat,
            manifest_name="manifest.json",
            max_bytes=self.max_bytes,
            patterns=PATTERNS,
            syncthing=str(self.syncthing),
            stamp="20261111T000000Z",
        )

    def test_decrypt_installs_the_canonical_tree_and_emits_a_batch(self):
        heartbeat = self.run_once()

        self.assertEqual("ok", heartbeat["status"])
        self.assertEqual(4, heartbeat["consumed"])
        self.assertEqual("zip", (self.target / "sms/messages-2026-11-10.zip").read_text())
        # SMS Import/Export cannot split contacts, so the service routes them.
        self.assertTrue((self.target / "contacts/contacts-2026-11-10.json").is_file())
        self.assertTrue((self.target / "health/health_2026-11-10.json").is_file())
        self.assertFalse((self.target / "sms/contacts-2026-11-10.json").exists())

        manifest = json.loads((self.target / "manifest.json").read_text())
        self.assertEqual("phone", manifest["source"])
        self.assertEqual(4, len(manifest["files"]))
        self.assertEqual(["sms/notes.txt"], [item["path"] for item in manifest["rejected"]])

        batches = sorted(self.batches.glob("phone-*.json"))
        self.assertEqual(1, len(batches))
        envelope = json.loads(batches[0].read_text())
        self.assertEqual(
            {"v", "source", "kind", "seq", "sent_at", "items"},
            set(envelope),
        )
        self.assertEqual(("phone", "batch", 1), (envelope["source"], envelope["kind"], envelope["seq"]))
        self.assertEqual(4, len(envelope["items"]))

        self.assertEqual(1, json.loads(self.state.read_text())["seq"])
        self.assertEqual(0o400, stat.S_IMODE(self.staged.stat().st_mode))
        # The heartbeat carries the phone's export date, so a silent phone is visible as
        # stale even while the hourly decrypt keeps succeeding.
        self.assertEqual("2026-11-10T00:00:00+00:00", heartbeat["source_export_at"])
        self.assertIsNotNone(heartbeat["source_export_epoch"])
        self.assertIsNotNone(heartbeat["source_age_s"])

    def test_second_run_dedupes_and_emits_no_batch(self):
        self.run_once()
        before = len(list(self.batches.glob("phone-*.json")))
        heartbeat = self.run_once()

        self.assertEqual(0, heartbeat["consumed"])
        self.assertEqual(before, len(list(self.batches.glob("phone-*.json"))))
        self.assertEqual(4, heartbeat["files"])

    def test_modified_file_is_reinstalled(self):
        self.run_once()
        (self.plaintext / "health/health_2026-11-10.json").write_text('{"steps": 1}')
        self.run_once()
        self.assertEqual('{"steps": 1}', (self.target / "health/health_2026-11-10.json").read_text())
        self.assertEqual(2, len(list(self.batches.glob("phone-*.json"))))

    def test_oversized_file_is_rejected(self):
        self.max_bytes = 2
        self.run_once()
        manifest = json.loads((self.target / "manifest.json").read_text())
        rejected = {item["path"]: item["reason"] for item in manifest["rejected"]}
        self.assertEqual("size-cap", rejected["sms/messages-2026-11-10.zip"])
        self.assertFalse((self.target / "sms/messages-2026-11-10.zip").exists())

    def test_wrong_folder_type_does_not_touch_the_tree(self):
        (self.source / ".stfolder/syncthing-encryption_password_token").unlink()
        with self.assertRaises(self.decrypt.PhoneDecryptError) as raised:
            self.run_once()
        self.assertEqual(self.decrypt.EXIT_FOLDER, raised.exception.code)
        self.assertFalse(self.target.exists())

    def test_alert_envelope_is_written_for_a_failure(self):
        self.decrypt.failure_heartbeat(self.heartbeat, self.batches, 3, "20261111T000000Z", "boom")
        envelope = json.loads(next(self.batches.glob("phone-*.json")).read_text())
        self.assertEqual("alert", envelope["kind"])
        self.assertEqual("boom", envelope["items"][0]["error"])
        self.assertEqual("error", json.loads(self.heartbeat.read_text())["status"])


class ExportTimeTests(unittest.TestCase):
    def setUp(self):
        self.decrypt = load(PHONE, "phone_decrypt")

    def iso(self, epoch: int) -> str:
        return self.decrypt.datetime.fromtimestamp(
            epoch, self.decrypt.timezone.utc
        ).isoformat()

    def test_the_date_in_the_name_wins(self):
        epoch = self.decrypt.export_epoch("messages-2026-11-10.zip", 1_700_000_000)
        self.assertEqual("2026-11-10T00:00:00+00:00", self.iso(epoch))

    def test_a_name_without_a_date_uses_the_mtime(self):
        self.assertEqual(
            self.decrypt.export_epoch("calls-latest.json", 1_700_000_000), 1_700_000_000
        )

    def test_the_newest_accepted_export_wins(self):
        accepted = [
            ("sms", Path("/x/messages-2026-11-09.zip"), "messages-2026-11-09.zip", 1, 0),
            ("health", Path("/x/health_2026-11-10.json"), "health_2026-11-10.json", 1, 0),
        ]
        newest = self.decrypt.newest_export(accepted)
        self.assertEqual("2026-11-10T00:00:00+00:00", self.iso(newest))
        self.assertIsNone(self.decrypt.newest_export([]))


class SmsValidatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.validator = load(SMS_VALIDATOR, "validate_export")
        self.valid = REPO / "mobile/sms-ie/fixtures/valid"
        self.invalid = REPO / "mobile/sms-ie/fixtures/invalid"

    def tearDown(self):
        self.tmp.cleanup()

    def build_export(self, ndjson: Path, destination: Path) -> None:
        destination.mkdir(parents=True)
        with zipfile.ZipFile(destination / "messages-2026-11-10.zip", "w") as archive:
            archive.write(ndjson, "messages.ndjson")
        shutil.copy(self.valid / "calls-2026-11-10.json", destination)
        shutil.copy(self.valid / "contacts-2026-11-10.json", destination)

    def test_valid_fixtures_pass(self):
        export = self.root / "export"
        self.build_export(self.valid / "messages.ndjson", export)
        result = self.validator.validate(export)
        self.assertTrue(result["ok"], result["errors"])
        self.assertEqual(3, len(result["files"]))

    def test_invalid_call_log_fixture_fails(self):
        result = self.validator.validate_file(self.invalid / "calls-2026-11-10.json")
        self.assertTrue(any("missing duration" in error for error in result))

    def test_invalid_messages_fixture_fails(self):
        export = self.root / "export"
        self.build_export(self.invalid / "messages.ndjson", export)
        result = self.validator.validate(export)
        self.assertFalse(result["ok"])
        self.assertTrue(any("missing address" in error for error in result["errors"]))
        self.assertTrue(any("__recipient_addresses" in error for error in result["errors"]))

    def test_invalid_contacts_fixture_fails(self):
        result = self.validator.validate_file(self.invalid / "contacts-2026-11-10.json")
        self.assertTrue(any("missing or non-scalar _id" in error for error in result))

    def test_unknown_filename_fails(self):
        stray = self.root / "messages.json"
        stray.write_text("{}")
        self.assertIn("unknown export filename", self.validator.validate_file(stray)[0])


class ManifestCheckerTests(unittest.TestCase):
    def test_good_fixture_passes(self):
        proc = subprocess.run(
            ["bash", str(VERIFY_MANIFEST), str(FIXTURES / "good")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, proc.returncode, proc.stderr)

    def test_internet_permission_fails(self):
        proc = subprocess.run(
            ["bash", str(VERIFY_MANIFEST), str(FIXTURES / "bad-internet")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(1, proc.returncode)
        self.assertIn("android.permission.INTERNET", proc.stderr)

    def test_drive_dependency_or_code_fails(self):
        proc = subprocess.run(
            ["bash", str(VERIFY_MANIFEST), str(FIXTURES / "bad-drive")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(1, proc.returncode)
        self.assertIn("google-api-services-drive", proc.stderr)
        self.assertIn("DriveManager.kt", proc.stderr)


class ConfigContractTests(unittest.TestCase):
    """The Nix modules' hard contracts; the eval-time assertions repeat them."""

    def test_untrusted_folder_is_receiveencrypted_and_owner_only(self):
        source = (REPO / "modules/nixos/vault-sync.nix").read_text()
        self.assertIn('folders.${phone.folderId}', source)
        self.assertIn('type = "receiveencrypted";', source)
        self.assertIn('"d ${phoneStore} 0700 vault vault -"', source)
        self.assertIn('devices = [ "phone" ];', source)

    def test_kanbei_share_is_read_only(self):
        source = (REPO / "modules/nixos/kanbei-vm.nix").read_text()
        self.assertIn("readOnly = true;", source)
        self.assertIn("source = phone.hostFolder;", source)
        self.assertIn("mountPoint = phone.guestMount;", source)

    def test_decrypt_service_refuses_missing_password_and_wrong_folder(self):
        source = (REPO / "modules/lib/phone/phone_decrypt.py").read_text()
        self.assertIn("EXIT_PASSWORD", source)
        self.assertIn("EXIT_FOLDER", source)
        self.assertIn("--contract", source)

    def test_path_contract_is_shared(self):
        source = (REPO / "modules/lib/phone-pipeline.nix").read_text()
        for value in (
            '"/var/lib/data/phone-untrusted"',
            '"/mnt/kanbei/phone-untrusted"',
            '"/var/lib/kanbei/phone"',
            '"/run/secrets/phone-folder-password"',
        ):
            self.assertIn(value, source)


if __name__ == "__main__":
    unittest.main()
