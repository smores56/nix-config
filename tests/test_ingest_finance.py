"""Unit tests for the SimpleFIN/Plaid finance collector (smores56/sdlc#590).

Covers protocol v1 and v2 parsing, `errlist`/`errors` handling, hledger journal
rendering and deterministic account names, cursor persistence, dedupe, batch
envelopes, the Plaid `/transactions/sync` cursor loop and secret redaction. No
socket is opened: every HTTP call goes through a fake opener.
"""

from __future__ import annotations

import base64
import importlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

INGEST = Path(__file__).parents[1] / "modules/lib/ingest"
ACCESS = "https://owner:s3cret@bridge.simplefin.org/simplefin"


def load(name: str):
    if str(INGEST) not in sys.path:
        sys.path.insert(0, str(INGEST))
    module = importlib.import_module(name)
    getattr(module, "_SECRETS", set()).clear()
    return module


class FakeResponse:
    def __init__(self, body: bytes, headers: dict[str, str] | None = None):
        self._body = body
        self.headers = headers or {"Content-Type": "application/json"}

    def read(self, size: int = -1) -> bytes:
        return self._body if size < 0 else self._body[:size]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    def __init__(self, documents: list[object]):
        self.documents = list(documents)
        self.requests: list[object] = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        document = self.documents.pop(0)
        return FakeResponse(json.dumps(document).encode())


def auth(pair: str) -> str:
    return "Basic " + base64.b64encode(pair.encode()).decode()


def v2_document(transactions=None, errlist=None):
    return {
        "errlist": errlist or [],
        "connections": [
            {"conn_id": "CON-1", "name": "My Bank - Jeff", "org_id": "ORG-1", "org_url": "https://bank.test"}
        ],
        "accounts": [
            {
                "id": "2930002",
                "name": "Savings",
                "conn_id": "CON-1",
                "conn_name": "My Bank - Jeff",
                "currency": "USD",
                "balance": "100.2300",
                "available-balance": "75.23",
                "balance-date": 1700000000,
                "transactions": transactions if transactions is not None else [],
            }
        ],
    }


def txn(txn_id="t1", posted=1700000100, amount="-33.43", description="Uncle Frank's Bait Shop"):
    return {"id": txn_id, "posted": posted, "amount": amount, "description": description}


class EnvTests(unittest.TestCase):
    def setUp(self):
        self.finance = load("finance")

    def test_parse_env_is_strict(self):
        self.assertEqual(self.finance.parse_env("A=1\n# c\nB='two words'\n"), {"A": "1", "B": "two words"})
        for text in ("A=1\nA=2\n", "lower=1\n", "novalue\n", "export A=1\n"):
            with self.subTest(text=text), self.assertRaises(self.finance.FinanceError):
                self.finance.parse_env(text)

    def test_session_requires_https_basic_credentials(self):
        session = self.finance.session_of({"SIMPLEFIN_ACCESS_URL": ACCESS})
        self.assertEqual(session["lookback_days"], 90)
        self.assertIsNone(session["plaid"])
        for bad in (
            "http://owner:s3cret@bridge.simplefin.org/simplefin",
            "https://bridge.simplefin.org/simplefin",
            "https://owner@bridge.simplefin.org/simplefin",
        ):
            with self.subTest(bad=bad), self.assertRaises(self.finance.FinanceError):
                self.finance.session_of({"SIMPLEFIN_ACCESS_URL": bad})

    def test_unknown_keys_and_plaid_switch(self):
        with self.assertRaises(self.finance.FinanceError):
            self.finance.session_of({"SIMPLEFIN_ACCESS_URL": ACCESS, "EXTRA": "1"})
        with self.assertRaises(self.finance.FinanceError):
            self.finance.session_of({"SIMPLEFIN_ACCESS_URL": ACCESS, "PLAID_ENABLED": "1"})
        env = {
            "SIMPLEFIN_ACCESS_URL": ACCESS,
            "PLAID_ENABLED": "1",
            "PLAID_ENV": "production",
            "PLAID_CLIENT_ID": "cid",
            "PLAID_SECRET": "sec",
            "PLAID_ITEMS_JSON": json.dumps([{"item_id": "i1", "access_token": "tok"} ]),
        }
        session = self.finance.session_of(env)
        self.assertEqual(session["plaid"]["items"][0]["item_id"], "i1")

    def test_redaction_never_logs_the_access_url(self):
        self.finance.register_secrets(ACCESS)
        self.assertEqual(self.finance.redact_url(ACCESS), "https://bridge.simplefin.org/simplefin")
        self.assertNotIn("s3cret", self.finance.redact_text(f"failed {ACCESS}"))
        self.assertNotIn("owner", self.finance.redact_text("https://owner:pw@bridge.simplefin.org/x"))


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.finance = load("finance")

    def test_the_access_url_reaches_the_proxy_without_userinfo(self):
        self.assertEqual(
            self.finance.accounts_url(ACCESS, None),
            "https://bridge.simplefin.org/simplefin/accounts?version=2",
        )
        self.assertEqual(self.finance.auth_header(ACCESS), auth("owner:s3cret"))

    def test_credentials_are_percent_decoded(self):
        url = "https://o%3Awn:p%40ss@beta-bridge.simplefin.org/simplefin"
        self.assertEqual(self.finance.auth_header(url), auth("o:wn:p@ss"))
        self.assertEqual(
            self.finance.accounts_url(url, None),
            "https://beta-bridge.simplefin.org/simplefin/accounts?version=2",
        )
        self.assertIsNotNone(self.finance.session_of({"SIMPLEFIN_ACCESS_URL": url}))

class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.finance = load("finance")

    def test_v2_parsing(self):
        parsed = self.finance.parse_account_set(v2_document([txn()]))
        self.assertEqual(parsed["version"], 2)
        account = parsed["accounts"][0]
        self.assertEqual(account["conn_name"], "My Bank - Jeff")
        self.assertEqual(account["balance"], "100.23")
        self.assertEqual(account["transactions"][0]["amount"], "-33.43")

    def test_v1_fallback(self):
        document = {
            "errors": ["My Bank needs attention"],
            "accounts": [
                {
                    "id": "a1",
                    "name": "Checking",
                    "org": {"id": "o1", "name": "My Bank", "url": "https://bank.test"},
                    "currency": "USD",
                    "balance": "5.00",
                    "balance-date": 1700000000,
                    "transactions": [txn()],
                }
            ],
        }
        parsed = self.finance.parse_account_set(document)
        self.assertEqual(parsed["version"], 1)
        self.assertEqual(parsed["accounts"][0]["conn_id"], "o1")
        self.assertEqual(parsed["errors"][0]["code"], "v1.error")
        self.assertFalse(self.finance.is_fatal(parsed["errors"][0]))

    def test_errlist_scope_and_fatal_codes(self):
        alert = {"code": "con.auth", "msg": "Login failed", "conn_id": "CON-1"}
        partial = {"code": "act.missingdata", "msg": "Try later", "account_id": "2930002"}
        fatal = {"code": "gen.auth", "msg": "No credentials"}
        parsed = self.finance.parse_account_set(v2_document(errlist=[alert, partial]))
        self.assertEqual({a["id"] for a in parsed["accounts"]}, {"2930002"})
        self.assertEqual(self.finance.error_scope(parsed, alert), {"2930002"})
        self.assertEqual(self.finance.error_scope(parsed, partial), {"2930002"})
        self.assertTrue(self.finance.is_fatal(fatal))
        self.assertFalse(self.finance.is_fatal(alert))
        self.assertTrue(self.finance.is_fatal({"code": "gen.unknown", "msg": "x"}))

    def test_account_set_shape_is_refused(self):
        for document in ([], {}, {"accounts": {}}, {"errlist": [], "connections": [], "accounts": {}}):
            with self.subTest(document=document), self.assertRaises(self.finance.FinanceError):
                self.finance.parse_account_set(document)


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.finance = load("finance")

    def account(self, name="Savings", conn="My Bank - Jeff", account_id="a1"):
        return {
            "id": account_id,
            "name": name,
            "conn_id": "c1",
            "conn_name": conn,
            "currency": "USD",
            "balance": "100.23",
            "available_balance": None,
            "balance_date": 1700000000,
            "transactions": [],
        }

    def test_account_paths_are_deterministic_and_collision_safe(self):
        paths = self.finance.unique_paths(
            [
                self.account("Savings", "My Bank", "a1"),
                self.account("Savings", "My Bank", "a2"),
                self.account("Café / Checking", "Other Bank", "a3"),
            ]
        )
        self.assertEqual(len(set(paths.values())), 3)
        self.assertEqual(paths["a1"], paths["a1"])
        first = self.finance.unique_paths([self.account()])
        self.assertEqual(first["a1"], "assets:bank:my-bank-jeff:savings")

    def test_journal_rendering(self):
        account = self.account()
        journal = self.finance.render_journal(account, "assets:bank:my-bank-jeff:savings", [txn()])
        self.assertIn("2023-11-14 * Uncle Frank's Bait Shop", journal)
        self.assertIn("USD 33.43", journal)
        self.assertIn("USD -33.43", journal)
        self.assertIn("expenses:unknown", journal)
        deposit = dict(txn(amount="12.50", description="Payroll"))
        rendered = self.finance.render_transaction(
            deposit, "assets:bank:my-bank-jeff:savings", "USD", "k" * 32
        )
        self.assertIn("income:unknown", rendered)
        self.assertIn("USD 12.50", rendered)

    def test_custom_currency_is_quoted(self):
        rendered = self.finance.render_transaction(
            txn(amount="3.0"), "assets:bank:x:y", "https://example.test/miles", "k" * 32
        )
        self.assertIn('"ccy-', rendered)

    def test_dedupe_key_is_stable(self):
        first = self.finance.transaction_key("a1", 1700000100, "-33.43", "Shop")
        self.assertEqual(first, self.finance.transaction_key("a1", 1700000100, "-33.4300", "  Shop "))
        self.assertNotEqual(first, self.finance.transaction_key("a1", 1700000101, "-33.43", "Shop"))


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.finance = load("finance")
        self.session = self.finance.session_of({"SIMPLEFIN_ACCESS_URL": ACCESS})

    def run_collect(self, opener, state, directory, now=1700000500):
        return self.finance.collect(
            self.session, state, os.path.join(directory, "outbox"), opener=opener, now=now
        )

    def batches(self, directory):
        outbox = os.path.join(directory, "outbox")
        payloads = []
        for name in sorted(os.listdir(outbox)):
            with open(os.path.join(outbox, name), encoding="utf-8") as handle:
                payloads.append(json.load(handle))
        return payloads

    def test_cursor_persistence_and_dedupe(self):
        with tempfile.TemporaryDirectory() as directory:
            state = self.finance.load_state(os.path.join(directory, "state.json"))
            opener = FakeOpener([v2_document([txn()])])
            summary = self.run_collect(opener, state, directory)
            self.assertEqual(summary["transactions"], 1)
            self.assertEqual(state["cursor"], 1700000500)
            request = opener.requests[0]
            # The claim's credentials travel as a header: a URL userinfo reaches the
            # proxy tunnel and dies as `InvalidURL: nonnumeric port`.
            self.assertEqual(request.full_url.split("?")[0], "https://bridge.simplefin.org/simplefin/accounts")
            self.assertNotIn("s3cret", request.full_url)
            self.assertEqual(request.get_header("Authorization"), auth("owner:s3cret"))
            self.assertIn("start-date=", opener.requests[0].full_url)
            # A replay inside the overlap re-fetches but emits nothing new.
            opener = FakeOpener([v2_document([txn()])])
            summary = self.run_collect(opener, state, directory, now=1700000600)
            self.assertEqual(summary["transactions"], 0)
            self.assertIn("start-date=1699741300", opener.requests[0].full_url)
            self.assertEqual(len(self.batches(directory)), 3)  # journal, balance, then a fresh balance
            for payload in self.batches(directory):
                self.assertEqual(payload["v"], 1)
                self.assertEqual(payload["source"], "finance")
                self.assertIn(payload["kind"], ("batch", "alert"))

    def test_pending_and_duplicate_transactions_are_skipped(self):
        pending = dict(txn(txn_id="p1"), pending=True)
        with tempfile.TemporaryDirectory() as directory:
            state = self.finance.load_state(os.path.join(directory, "state.json"))
            summary = self.run_collect(FakeOpener([v2_document([txn(), txn(), pending])]), state, directory)
            self.assertEqual(summary["transactions"], 1)

    def test_alerts_hold_the_cursor(self):
        with tempfile.TemporaryDirectory() as directory:
            state = self.finance.load_state(os.path.join(directory, "state.json"))
            document = v2_document([txn()], errlist=[{"code": "act.failed", "msg": "later", "account_id": "2930002"}])
            summary = self.run_collect(FakeOpener([document]), state, directory)
            self.assertEqual(summary["alerts"], 1)
            self.assertFalse(summary["fatal"])
            self.assertEqual(state["cursor"], 0)
            # The affected account is excluded, so its transactions were not emitted.
            self.assertEqual(summary["transactions"], 0)
            self.assertEqual(self.batches(directory)[0]["kind"], "alert")

    def test_fatal_error_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            state = self.finance.load_state(os.path.join(directory, "state.json"))
            document = v2_document(errlist=[{"code": "gen.auth", "msg": "revoked"}])
            summary = self.run_collect(FakeOpener([document]), state, directory)
            self.assertTrue(summary["fatal"])

    def test_balances_are_emitted_without_transactions(self):
        with tempfile.TemporaryDirectory() as directory:
            state = self.finance.load_state(os.path.join(directory, "state.json"))
            summary = self.run_collect(FakeOpener([v2_document()]), state, directory)
            self.assertEqual(summary["transactions"], 0)
            batches = self.batches(directory)
            self.assertEqual(len(batches), 1)
            self.assertEqual(batches[0]["items"][0]["type"], "finance-balance")
            self.assertEqual(batches[0]["items"][0]["account"], "assets:bank:my-bank-jeff:savings")


class PlaidTests(unittest.TestCase):
    def setUp(self):
        self.plaid = load("plaid")

    def session(self):
        return self.plaid.session_of(
            {
                "PLAID_ENABLED": "1",
                "PLAID_ENV": "production",
                "PLAID_CLIENT_ID": "cid",
                "PLAID_SECRET": "sec",
                "PLAID_ITEMS_JSON": json.dumps([{"item_id": "i1", "access_token": "tok", "institution": "Chase"}]),
            }
        )

    def test_production_only_and_item_contract(self):
        for env in (
            {"PLAID_ENABLED": "1", "PLAID_ENV": "sandbox", "PLAID_CLIENT_ID": "c", "PLAID_SECRET": "s", "PLAID_ITEMS_JSON": "[]"},
            {"PLAID_ENABLED": "1", "PLAID_ENV": "production", "PLAID_CLIENT_ID": "", "PLAID_SECRET": "s", "PLAID_ITEMS_JSON": "[]"},
            {"PLAID_ENABLED": "0", "PLAID_ENV": "production"},
        ):
            with self.subTest(env=env), self.assertRaises(self.plaid.PlaidError):
                self.plaid.session_of(env)

    def test_sync_cursor_loop_and_sign_flip(self):
        first = {
            "added": [
                {
                    "transaction_id": "tx1",
                    "account_id": "acc1",
                    "amount": 10.0,
                    "date": "2026-01-02",
                    "name": "Coffee",
                }
            ],
            "modified": [],
            "removed": [],
            "next_cursor": "cur2",
            "has_more": True,
            "accounts": [
                {
                    "account_id": "acc1",
                    "name": "Checking",
                    "balances": {"current": 100.5, "available": 90.0, "iso_currency_code": "USD"},
                }
            ],
        }
        second = {
            "added": [],
            "modified": [],
            "removed": [{"transaction_id": "tx0", "account_id": "acc1"}],
            "next_cursor": "cur3",
            "has_more": False,
            "accounts": [],
        }
        opener = FakeOpener([first, second])
        state = {"plaid": {}}
        accounts, errors, removed = self.plaid.collect(self.session(), state, now=1700000000, opener=opener)
        self.assertEqual(errors, [])
        self.assertEqual(state["plaid"]["i1"]["cursor"], "cur3")
        self.assertEqual(accounts[0]["balance"], "100.5")
        self.assertEqual(accounts[0]["transactions"][0]["amount"], "-10")
        self.assertEqual(removed[0]["transaction_id"], "tx0")
        self.assertEqual(len(opener.requests), 2)
        self.assertIn("plaid-client-id", {k.lower() for k in opener.requests[0].headers})

    def test_api_error_holds_the_cursor(self):
        opener = FakeOpener([{"error_code": "ITEM_LOGIN_REQUIRED", "display_message": "Reconnect"}])
        state = {"plaid": {"i1": {"cursor": "old"}}}
        accounts, errors, removed = self.plaid.collect(self.session(), state, now=1700000000, opener=opener)
        self.assertEqual(accounts, [])
        self.assertEqual(errors[0]["code"], "plaid.ITEM_LOGIN_REQUIRED")
        self.assertEqual(state["plaid"]["i1"]["cursor"], "old")
        self.assertEqual(removed, [])

    def test_link_token_is_human_gated(self):
        opener = FakeOpener([{"link_token": "link-sandbox-abc"}])
        token = self.plaid.link_token_create(self.session(), "owner", opener=opener)
        self.assertEqual(token, "link-sandbox-abc")
        self.assertIn("/link/token/create", opener.requests[0].full_url)


class CliTests(unittest.TestCase):
    def test_main_writes_state_and_never_prints_the_access_url(self):
        finance = load("finance")
        with tempfile.TemporaryDirectory() as directory:
            env = os.path.join(directory, "env")
            with open(env, "w", encoding="utf-8") as handle:
                handle.write(f"SIMPLEFIN_ACCESS_URL={ACCESS}\n")
            outbox = os.path.join(directory, "outbox")

            original = finance.http_json
            finance.http_json = lambda url, **kwargs: v2_document([txn()])
            try:
                buffer = io.StringIO()
                with redirect_stdout(buffer):
                    code = finance.main(
                        ["--env", env, "--outbox", outbox, "--state", os.path.join(directory, "state.json")]
                    )
            finally:
                finance.http_json = original
            self.assertEqual(code, 0)
            output = buffer.getvalue()
            self.assertNotIn("s3cret", output)
            self.assertNotIn(ACCESS, output)
            self.assertTrue(os.path.isfile(os.path.join(directory, "state.json")))


if __name__ == "__main__":
    unittest.main()
