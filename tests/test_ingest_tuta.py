"""Unit tests for the Tuta and cluster-digest ingest paths (smores56/sdlc#589, #595).

Covers the pure halves: the secret-device env contract and archive extraction,
the mail collector's folder classification, UID/UIDVALIDITY dedupe, MIME
summarising, batch chunking, bridge-log rejection scanning, and the digest
writer's stable read, `generated_at` cursor, atomic state and staleness alert.
No IMAP connection, no age binary and no Tuta account are needed.
"""

from __future__ import annotations

import base64
import importlib
import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

INGEST = Path(__file__).parents[1] / "modules/lib/ingest"
VALID_RECIPIENT = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"


def load(name: str):
    if str(INGEST) not in sys.path:
        sys.path.insert(0, str(INGEST))
    return importlib.import_module(name)


def archive(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o600
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


CONFIG = b'email = "owner@tuta.com"\nbridge_password = "secret"\n'
SESSION_FILES = {
    "gnupg/pubring.kbx": b"keyring",
    "pass/tuta/bridge/owner@tuta.com.gpg": b"entry",
    "config/tutabridge/config.toml": CONFIG,
}


def session_env(**overrides: str) -> dict[str, str]:
    values = {
        "TUTA_ADDRESS": "owner@tuta.com",
        "TUTA_SESSION_B64": base64.b64encode(archive(SESSION_FILES)).decode(),
    }
    values.update(overrides)
    return values


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.session = load("tuta_session")

    def test_parse_env_is_strict(self):
        parsed = self.session.parse_env("A=1\n# comment\nB='two words'\n")
        self.assertEqual(parsed, {"A": "1", "B": "two words"})
        for text in ("A=1\nA=2\n", "lower=1\n", "novalue\n", "A=1\nexport B=2\n"):
            with self.subTest(text=text), self.assertRaises(self.session.SessionError):
                self.session.parse_env(text)

    def test_session_requires_address_and_rejects_unknown_keys(self):
        with self.assertRaises(self.session.SessionError):
            self.session.session_of({})
        with self.assertRaises(self.session.SessionError):
            self.session.session_of({"TUTA_ADDRESS": "not-an-address"})
        with self.assertRaises(self.session.SessionError):
            self.session.session_of({"TUTA_ADDRESS": "a@b.co", "EXTRA": "1"})
        with self.assertRaises(self.session.SessionError):
            self.session.session_of(session_env(TUTA_PASS_PATH="/absolute"))
        with self.assertRaises(self.session.SessionError):
            self.session.session_of(session_env(TUTA_PASS_PATH="../escape"))

    def test_archive_decoding(self):
        self.assertEqual(len(self.session.decode_archive(base64.b64encode(b"x").decode())), 1)
        with self.assertRaises(self.session.SessionError):
            self.session.decode_archive("not base64!")
        with self.assertRaises(self.session.SessionError):
            self.session.decode_archive(base64.b64encode(b"x" * (self.session.MAX_SESSION_BYTES + 1)).decode())

    def test_extract_refuses_traversal_and_links(self):
        for files in (
            {"pass/../../etc/passwd": b"x"},
            {"/etc/passwd": b"x"},
            {"other/thing": b"x"},
        ):
            with self.subTest(files=files):
                with self.assertRaises(self.session.SessionError):
                    with tempfile.TemporaryDirectory() as root:
                        self.session.safe_extract(archive(files), root)
        link = io.BytesIO()
        with tarfile.open(fileobj=link, mode="w:gz") as tar:
            info = tarfile.TarInfo("pass/link")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            tar.addfile(info)
        with self.assertRaises(self.session.SessionError):
            with tempfile.TemporaryDirectory() as root:
                self.session.safe_extract(link.getvalue(), root)

    def test_stage_writes_loopback_config_and_runtime(self):
        env = session_env()
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "root")
            run = os.path.join(tmp, "run")
            result = self.session.stage(
                env, root=root, runtime_dir=run, imap_port=1143, smtp_port=1025, sync_limit=50
            )
            self.assertEqual(result["address"], "owner@tuta.com")
            with open(os.path.join(root, "config/tutabridge/config.toml"), encoding="utf-8") as handle:
                config = handle.read()
            self.assertIn('bind_addr = "127.0.0.1"', config)
            self.assertIn("imap_port = 1143", config)
            self.assertIn("smtp_port = 1025", config)
            self.assertIn('pass_path = "tuta/bridge"', config)
            self.assertIn("sync_limit = 50", config)
            # The staged config's bridge password survives the rewrite.
            self.assertIn('bridge_password = "secret"', config)
            self.assertEqual(oct(os.stat(os.path.join(run, "bridge-password")).st_mode & 0o777), "0o600")
            with open(os.path.join(run, "address"), encoding="utf-8") as handle:
                self.assertEqual(handle.read().strip(), "owner@tuta.com")

    def test_stage_requires_a_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(self.session.SessionError):
                self.session.stage(
                    {"TUTA_ADDRESS": "owner@tuta.com"},
                    root=os.path.join(tmp, "root"),
                    runtime_dir=os.path.join(tmp, "run"),
                    imap_port=1143,
                    smtp_port=1025,
                    sync_limit=50,
                )

    def test_bridge_password_precedence(self):
        env_session = self.session.session_of(session_env(TUTA_BRIDGE_PASSWORD="from-env"))
        self.assertEqual(self.session.bridge_password(env_session, CONFIG.decode()), "from-env")
        staged = self.session.session_of({"TUTA_ADDRESS": "owner@tuta.com"})
        self.assertEqual(self.session.bridge_password(staged, CONFIG.decode()), "secret")
        with self.assertRaises(self.session.SessionError):
            self.session.bridge_password(staged, 'email = "owner@tuta.com"\n')


class MailTests(unittest.TestCase):
    def setUp(self):
        self.mail = load("tuta_mail")

    def test_folder_classification(self):
        for name in ("Sent", "sent", "Sent Items", "Café/Sent"):
            self.assertTrue(self.mail.is_sent_folder(name), name)
        for name in ("INBOX", "inbox", "Archive", "Drafts"):
            self.assertFalse(self.mail.is_sent_folder(name), name)
        self.assertEqual(self.mail.folder_kind("INBOX"), "inbox")
        self.assertEqual(self.mail.folder_kind("notes/today"), "other")

    def test_first_sight_baselines_then_delta(self):
        state = {"folders": {}}
        fresh, action = self.mail.plan_folder(state, "INBOX", 7, [1, 2, 3])
        self.assertEqual((fresh, action), ([], "baseline"))
        self.assertEqual(state["folders"]["INBOX"]["uids"], [1, 2, 3])
        fresh, action = self.mail.plan_folder(state, "INBOX", 7, [1, 2, 3, 4])
        self.assertEqual((fresh, action), ([4], "delta"))

    def test_uidvalidity_change_rebaselines_without_replay(self):
        state = {"folders": {"INBOX": {"uidvalidity": 7, "uids": [1, 2]}}}
        fresh, action = self.mail.plan_folder(state, "INBOX", 8, [1, 2, 3])
        self.assertEqual((fresh, action), ([], "uidvalidity-reset"))
        self.assertEqual(state["folders"]["INBOX"]["uidvalidity"], 8)

    def test_no_baseline_backfills_once(self):
        state = {"folders": {}}
        fresh, action = self.mail.plan_folder(state, "INBOX", 7, [1, 2], baseline=False)
        self.assertEqual((fresh, action), ([1, 2], "backfill"))
        fresh, _ = self.mail.plan_folder(state, "INBOX", 7, [1, 2])
        self.assertEqual(fresh, [])

    def test_uid_lists_are_deduplicated_and_capped(self):
        self.assertEqual(self.mail.uid_list([b"3 1 2", b"2 4"]), [1, 2, 3, 4])
        self.assertEqual(self.mail.uid_list(None), [])
        self.assertEqual(self.mail.uid_list([b"not-a-number 5"]), [5])
        self.assertEqual(self.mail.merge_uids([1, 2], [2, 3], keep=2), [2, 3])
        self.assertEqual(self.mail.new_uids([1], [1, 2]), [2])

    def message(self) -> bytes:
        return (
            b"From: Alice <alice@example.test>\r\n"
            b"To: owner@tuta.com\r\n"
            b"Subject: =?utf-8?b?SGVsbG8=?=\r\n"
            b"Date: Thu, 01 Jan 2026 09:00:00 +0000\r\n"
            b"Message-ID: <abc@example.test>\r\n"
            b"MIME-Version: 1.0\r\n"
            b"Content-Type: multipart/mixed; boundary=cut\r\n\r\n"
            b"--cut\r\n"
            b"Content-Type: multipart/alternative; boundary=alt\r\n\r\n"
            b"--alt\r\n"
            b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
            b"plain body\r\n"
            b"--alt\r\n"
            b"Content-Type: text/html; charset=utf-8\r\n\r\n"
            b"<p>html &amp; body</p>\r\n"
            b"--alt--\r\n"
            b"--cut\r\n"
            b"Content-Type: application/octet-stream\r\n"
            b"Content-Disposition: attachment; filename=big.bin\r\n\r\n"
            b"BINARY" * 100 + b"\r\n"
            b"--cut--\r\n"
        )

    def test_summarize_prefers_text_and_caps_body(self):
        item = self.mail.summarize(self.message(), "INBOX", 42, 4096)
        self.assertEqual(item["subject"], "Hello")
        self.assertEqual(item["message_id"], "<abc@example.test>")
        self.assertEqual(item["body"].strip(), "plain body")
        self.assertEqual(item["uid"], 42)
        capped = self.mail.summarize(self.message(), "INBOX", 42, 4)
        self.assertEqual(capped["body"], "plai")

    def test_html_only_body_is_stripped(self):
        raw = (
            b"Content-Type: text/html; charset=utf-8\r\n\r\n<p>a &amp; b</p>"
        )
        self.assertEqual(self.mail.summarize(raw, "INBOX", 1, 4096)["body"].strip(), "a & b")

    def test_sent_alert_has_no_body(self):
        item = self.mail.summarize(self.message(), "Sent", 9, 4096)
        alert = self.mail.sent_alert(item)
        self.assertEqual(alert["type"], "sent-alert")
        self.assertNotIn("body", alert)
        self.assertEqual(alert["uid"], 9)

    def test_batches_validate_and_chunk(self):
        items = [{"type": "mail", "uid": index, "body": "x" * 100} for index in range(5)]
        payload = self.mail.batch_bytes("tuta", "alert", 1, items[:1], size_cap=65536)
        envelope = json.loads(payload)
        self.assertEqual(envelope["kind"], "alert")
        self.assertEqual(envelope["seq"], 1)
        chunks = self.mail.chunk_items(items, max_items=2, max_bytes=65536)
        self.assertEqual([len(chunk) for chunk in chunks], [2, 2, 1])
        with self.assertRaises(self.mail.MailError):
            self.mail.chunk_items([{"body": "x" * 70000}], max_items=1, max_bytes=65536)

    def test_emit_batches_writes_outbox_and_seq(self):
        state = {"seq": 0, "folders": {}, "alerts": {}}
        with tempfile.TemporaryDirectory() as outbox:
            written = self.mail.emit_batches(
                outbox,
                state,
                "alert",
                [{"type": "client-rejection", "reason": "minimum-client"}],
                max_items=50,
                max_bytes=65536,
            )
            self.assertEqual(len(written), 1)
            self.assertEqual(state["seq"], 1)
            with open(written[0], encoding="utf-8") as handle:
                self.assertEqual(json.load(handle)["kind"], "alert")

    def test_rejection_patterns(self):
        self.assertEqual(
            self.mail.rejection_reason("Tuta rejects this version; update the image: docker compose pull"),
            "minimum-client",
        )
        self.assertEqual(
            self.mail.rejection_reason("Saved session rejected; run tutabridge init (existing entry preserved)"),
            "session-rejected",
        )
        self.assertIsNone(self.mail.rejection_reason("Tuta temporarily unavailable; retrying with backoff"))

    def test_bridge_log_scan_is_offset_aware_and_rate_limited(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "bridge.log")
            state = {"log_offset": 0, "alerts": {}}
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("Starting IMAP and SMTP\nTuta rejects this version; update\n")
            self.assertEqual(self.mail.scan_bridge_log(path, state, now=1000, cooldown=86400), ["minimum-client"])
            self.assertEqual(self.mail.scan_bridge_log(path, state, now=1001, cooldown=86400), [])
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("Saved session rejected; run init\n")
            self.assertEqual(self.mail.scan_bridge_log(path, state, now=2000, cooldown=86400), ["session-rejected"])
            # Rotation: a shorter file rewinds the cursor instead of skipping lines.
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("Tuta rejects this version\n")
            self.assertEqual(self.mail.scan_bridge_log(path, state, now=200000, cooldown=86400), ["minimum-client"])

    def test_state_round_trip_and_bad_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            state = self.mail.load_state(path)
            self.assertEqual(state["seq"], 0)
            state["seq"] = 3
            self.mail.write_state(path, state)
            self.assertEqual(self.mail.load_state(path)["seq"], 3)
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"version": 99}, handle)
            with self.assertRaises(self.mail.MailError):
                self.mail.load_state(path)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("not json")
            with self.assertRaises(self.mail.MailError):
                self.mail.load_state(path)


class DigestTests(unittest.TestCase):
    def setUp(self):
        self.digest = load("digest")
        tree = {
            "schema_version": "1",
            "generated_at": "2026-01-01T00:00:00Z",
            "window": "15m",
            "source_freshness": {},
            "cluster": {"nodes": 1},
            "nanobot_activity": {"events": []},
        }
        self.document = json.dumps(tree).encode()

    def args(self, tmp: str, **overrides) -> Namespace:
        inbox = os.path.join(tmp, "inbox")
        state = os.path.join(tmp, "state")
        os.makedirs(inbox)
        os.makedirs(state)
        values = {
            "source": "cluster-digest",
            "file": os.path.join(tmp, "latest.json"),
            "recipient_file": os.path.join(tmp, "recipient"),
            "inbox": inbox,
            "state_dir": state,
            "interval": 1.0,
            "window": 3600,
            "max_bytes": 65536,
            "once": True,
            "stale_alert": False,
        }
        values.update(overrides)
        return Namespace(**values)

    def write_digest(self, path: str, payload: bytes) -> None:
        with open(path, "wb") as handle:
            handle.write(payload)

    def test_parse_timestamp_and_digest(self):
        self.assertEqual(self.digest.parse_timestamp("2026-01-01T00:00:00Z"), 1767225600)
        self.assertEqual(
            self.digest.parse_timestamp("2026-01-01T01:00:00+01:00"),
            self.digest.parse_timestamp("2026-01-01T00:00:00Z"),
        )
        for value in ("", "2026-01-01", "2026-01-01T00:00:00", 1, None):
            with self.subTest(value=value), self.assertRaises(self.digest.DigestError):
                self.digest.parse_timestamp(value)
        document, epoch = self.digest.parse_digest(self.document)
        self.assertEqual(document["schema_version"], "1")
        self.assertEqual(epoch, 1767225600)

    def test_parse_digest_refuses_changed_contract(self):
        for payload in (
            b"",
            b"not json",
            b'{"schema_version":"2","generated_at":"2026-01-01T00:00:00Z","cluster":{},"nanobot_activity":{}}',
            b'{"schema_version":"1","generated_at":"2026-01-01T00:00:00Z","cluster":{}}',
            b'{"schema_version":"1","generated_at":"2026-01-01T00:00:00Z","cluster":{},"nanobot_activity":[]}',
        ):
            with self.subTest(payload=payload[:30]), self.assertRaises(self.digest.DigestError):
                self.digest.parse_digest(payload)
        with self.assertRaises(self.digest.DigestError):
            self.digest.parse_digest(self.document, max_bytes=8)

    def test_cursor_is_strictly_newer(self):
        self.assertTrue(self.digest.is_newer(None, 10))
        self.assertFalse(self.digest.is_newer(10, 10))
        self.assertFalse(self.digest.is_newer(10, 9))
        self.assertTrue(self.digest.is_newer(9, 10))

    def test_read_stable_retries_across_a_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "latest.json")
            self.write_digest(path, b'{"a":1}')
            real_open = open
            calls = {"n": 0}

            # The write lands between stat and read, exactly like a rename or a
            # virtiofs update mid-read; the first attempt must be refused.
            def racy_open(target, mode="r", *args, **kwargs):
                calls["n"] += 1
                if calls["n"] == 1:
                    self.write_digest(path, b'{"a":22}')
                return real_open(target, mode, *args, **kwargs)

            self.digest.open = racy_open
            try:
                payload = self.digest.read_stable(path, delay=0)
            finally:
                del self.digest.open
            self.assertEqual(payload, b'{"a":22}')
            self.assertEqual(calls["n"], 2)

    def test_read_stable_gives_up_on_a_moving_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "latest.json")
            self.write_digest(path, b"x")
            real_open = open

            def always_open(target, mode="r", *args, **kwargs):
                self.write_digest(path, b"y" * 7)
                return real_open(target, mode, *args, **kwargs)

            self.digest.open = always_open
            try:
                with self.assertRaises(self.digest.DigestError):
                    self.digest.read_stable(path, delay=0, attempts=3)
            finally:
                del self.digest.open

    def test_read_stable_refuses_oversize_and_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "latest.json")
            self.write_digest(path, b"x" * 100)
            with self.assertRaises(self.digest.DigestError):
                self.digest.read_stable(path, max_bytes=10)
            with self.assertRaises(self.digest.DigestError):
                self.digest.read_stable(tmp)

    def test_cycle_emits_once_and_dedupes_on_generated_at(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(tmp)
            self.write_digest(args.file, self.document)
            with open(args.recipient_file, "w", encoding="utf-8") as handle:
                handle.write(VALID_RECIPIENT + "\n")

            seen: list[bytes] = []

            def fake_encrypt(_recipient: str, payload: bytes, directory: str) -> str:
                seen.append(payload)
                handle, path = tempfile.mkstemp(dir=directory, suffix=".age")
                with os.fdopen(handle, "wb") as out:
                    out.write(b"AGE" + payload)
                return path

            original = self.digest.writer.encrypt_to
            self.digest.writer.encrypt_to = fake_encrypt
            try:
                batches = self.digest.cycle(args, batches=0, started=0)
                self.assertEqual(batches, 1)
                self.assertEqual(len(seen), 1)
                files = sorted(os.listdir(args.inbox))
                self.assertEqual(files, ["cluster-digest-20260101T000000Z.age"])
                # Same document again: no second file, even though mtime changed.
                self.write_digest(args.file, self.document + b"\n")
                batches = self.digest.cycle(args, batches=batches, started=0)
                self.assertEqual(batches, 1)
                self.assertEqual(len(os.listdir(args.inbox)), 1)
                # A newer generated_at is emitted under its own stamp.
                newer = json.loads(self.document)
                newer["generated_at"] = "2026-01-01T00:15:00Z"
                self.write_digest(args.file, json.dumps(newer).encode())
                batches = self.digest.cycle(args, batches=batches, started=0)
                self.assertEqual(batches, 2)
                self.assertEqual(
                    sorted(os.listdir(args.inbox)),
                    [
                        "cluster-digest-20260101T000000Z.age",
                        "cluster-digest-20260101T001500Z.age",
                    ],
                )
                # An out-of-order (older) document is a replay, not an emit.
                older = json.loads(self.document)
                older["generated_at"] = "2025-12-31T23:45:00Z"
                self.write_digest(args.file, json.dumps(older).encode())
                self.assertEqual(self.digest.cycle(args, batches=batches, started=0), 2)
            finally:
                self.digest.writer.encrypt_to = original

    def test_cycle_waits_for_the_recipient_without_advancing_the_cursor(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(tmp)
            self.write_digest(args.file, self.document)
            self.assertEqual(self.digest.cycle(args, batches=0, started=0), 0)
            self.assertIsNone(self.digest.read_cursor(args.state_dir))
            self.assertEqual(os.listdir(args.inbox), [])

    def test_a_missing_digest_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(tmp)
            self.assertEqual(self.digest.cycle(args, batches=0, started=0), 0)

    def test_state_files_and_heartbeat_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(tmp)
            target = os.path.join(args.inbox, "cluster-digest-20260101T000000Z.age")
            self.write_digest(target, b"ciphertext")
            self.digest.record_state(args.state_dir, epoch=1767225600, target=target, batches=1)
            self.assertEqual(self.digest.read_cursor(args.state_dir), 1767225600)
            with open(os.path.join(args.state_dir, "cluster-digest.last-ok"), encoding="utf-8") as handle:
                last_ok = json.load(handle)
            self.assertEqual(last_ok["source"], "cluster-digest")
            self.assertEqual(last_ok["epoch"], 1767225600)
            self.assertEqual(last_ok["batches"], 1)
            self.assertEqual(oct(os.stat(os.path.join(args.state_dir, "cluster-digest.cursor")).st_mode & 0o777), "0o600")

    def test_alert_is_rate_limited_per_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls: list[list[str]] = []

            def run(argv, check=False):
                calls.append(list(argv))
                return Namespace(returncode=0)

            self.assertTrue(self.digest.alert(tmp, window=3600, now=1000, last_epoch=0, run=run))
            self.assertFalse(self.digest.alert(tmp, window=3600, now=2000, last_epoch=0, run=run))
            self.assertTrue(self.digest.alert(tmp, window=3600, now=5000, last_epoch=0, run=run))
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0], ["systemctl", "start", "--no-block", "cloudflare-email@ingest-writer-cluster-digest.service"])


class CalendarTests(unittest.TestCase):
    def setUp(self):
        self.ics = load("tuta_ics")

    def test_fingerprint_ignores_line_endings_and_trailing_space(self):
        state = {"seq": 0, "fingerprint": None, "unavailable_epoch": 0}
        self.assertEqual(
            self.ics.fingerprint("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"),
            self.ics.fingerprint("BEGIN:VCALENDAR  \nEND:VCALENDAR\n"),
        )
        self.assertTrue(self.ics.changed(state, "abc"))
        state["fingerprint"] = "abc"
        self.assertFalse(self.ics.changed(state, "abc"))

    def test_emit_writes_a_valid_alert_batch(self):
        state = {"seq": 0, "fingerprint": None, "unavailable_epoch": 0}
        with tempfile.TemporaryDirectory() as outbox:
            name = self.ics.emit(
                outbox,
                state,
                "alert",
                [{"type": "calendar-unavailable", "reason": "no SDK"}],
                max_bytes=65536,
            )
            self.assertIsNotNone(name)
            self.assertEqual(state["seq"], 1)
            with open(os.path.join(outbox, name), encoding="utf-8") as handle:
                envelope = json.load(handle)
            self.assertEqual(envelope["kind"], "alert")
            self.assertEqual(envelope["items"][0]["type"], "calendar-unavailable")
        with tempfile.TemporaryDirectory() as outbox:
            self.assertIsNone(
                self.ics.emit(outbox, state, "alert", [{"reason": "x" * 1000}], max_bytes=64)
            )

    def test_state_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            self.assertEqual(self.ics.load_state(path)["seq"], 0)
            self.ics.write_state(path, {"version": 1, "seq": 2, "fingerprint": "f", "unavailable_epoch": 5})
            loaded = self.ics.load_state(path)
            self.assertEqual((loaded["seq"], loaded["fingerprint"]), (2, "f"))


class AlertKindTests(unittest.TestCase):
    def setUp(self):
        self.policy = load("policy")

    def test_alert_batches_share_the_schema(self):
        for kind in ("batch", "alert"):
            payload = json.dumps({"v": 1, "source": "tuta", "kind": kind, "items": []}).encode()
            self.assertEqual(self.policy.validate_batch(payload, "tuta")["kind"], kind)
        with self.assertRaises(self.policy.PolicyError):
            self.policy.validate_batch(
                b'{"v":1,"source":"tuta","kind":"heartbeat","items":[]}', "tuta"
            )


if __name__ == "__main__":
    unittest.main()
