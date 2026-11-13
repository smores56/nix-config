"""Plaid fallback client for `ingest-finance` (smores56/sdlc#590).

SimpleFIN covers most institutions; Plaid is the fallback for one SimpleFIN
cannot reach. The client surface is only what the collector needs:

* `/link/token/create` — **human-gated**. The owner runs this once per Item in
  Plaid Link (host-side, with the owner present), and writes the resulting
  access token into the secret contract. It is never called by the timer.
* `/transactions/sync` — the cursor path. Added/modified/removed patches are
  fetched until `has_more` is false, and the returned `next_cursor` is persisted
  per Item; a failed Item keeps its old cursor and raises an alert.

Disabled by default (`PLAID_ENABLED=0`). Enabling it also has to add
`production.plaid.com` to the finance egress allowlist in
`modules/lib/ingest-vm.nix`; the table's `financeAllow` is the only switch.
Personal use is limited by Plaid's Trial plan (10 production Items, OAuth
institutions approved per Item), and no egress exists unless the owner sets it
up. The access token is a bearer credential and is stored only in the read-only
secret device.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import date, datetime, timezone
from decimal import Decimal
from urllib import error as urllib_error
from urllib import request as urllib_request

import policy

BASE_URL = "https://production.plaid.com"
ENV_KEYS = {"PLAID_ENABLED", "PLAID_ENV", "PLAID_CLIENT_ID", "PLAID_SECRET", "PLAID_ITEMS_JSON"}
MAX_RESPONSE_BYTES = 16 << 20
MAX_PAGES = 100
SYNC_COUNT = 500


class PlaidError(RuntimeError):
    """A refused Plaid configuration, response or Item list."""


def session_of(env: dict[str, str]) -> dict:
    if env.get("PLAID_ENABLED") != "1":
        raise PlaidError("Plaid is disabled")
    if env.get("PLAID_ENV") != "production":
        raise PlaidError("PLAID_ENV must be production; the egress allowlist has one host")
    client_id = env.get("PLAID_CLIENT_ID", "")
    secret = env.get("PLAID_SECRET", "")
    if not client_id or not secret:
        raise PlaidError("PLAID_CLIENT_ID and PLAID_SECRET are required")
    raw_items = env.get("PLAID_ITEMS_JSON", "")
    try:
        items = json.loads(raw_items) if raw_items else []
    except json.JSONDecodeError:
        raise PlaidError("PLAID_ITEMS_JSON is not JSON") from None
    if not isinstance(items, list) or not items:
        raise PlaidError("PLAID_ITEMS_JSON must be a non-empty list")
    parsed = []
    for raw in items:
        if not isinstance(raw, dict):
            raise PlaidError("PLAID_ITEMS_JSON entry is not an object")
        item_id = str(raw.get("item_id") or "")
        token = str(raw.get("access_token") or "")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,200}", item_id) or not re.fullmatch(r"[A-Za-z0-9._-]{1,400}", token):
            raise PlaidError("PLAID_ITEMS_JSON entry needs item_id and access_token")
        parsed.append(
            {
                "item_id": item_id,
                "access_token": token,
                "institution": str(raw.get("institution") or item_id)[:200],
            }
        )
    return {"base_url": BASE_URL, "client_id": client_id, "secret": secret, "items": parsed}


def request(
    session: dict,
    path: str,
    payload: dict,
    *,
    opener: urllib_request.OpenerDirector | None = None,
    timeout: float = 60.0,
) -> dict:
    body = json.dumps(payload).encode("utf-8")
    request = urllib_request.Request(
        session["base_url"] + path,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": policy.USER_AGENT,
            "PLAID-CLIENT-ID": session["client_id"],
            "PLAID-SECRET": session["secret"],
        },
    )
    open_url = (opener or urllib_request.build_opener()).open
    try:
        with open_url(request, timeout=timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib_error.HTTPError as exc:
        raw = exc.read(MAX_RESPONSE_BYTES) or b"{}"
        try:
            document = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            document = {}
        raise PlaidError(api_message(document) or f"Plaid returned HTTP {exc.code}") from None
    except (urllib_error.URLError, OSError, ValueError) as exc:
        raise PlaidError(f"Plaid request failed: {exc}") from None
    if len(raw) > MAX_RESPONSE_BYTES:
        raise PlaidError("Plaid response exceeds the size cap")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise PlaidError("Plaid response is not JSON") from None
    if not isinstance(document, dict):
        raise PlaidError("Plaid response is not an object")
    return document


def api_message(document: dict) -> str:
    return str(document.get("display_message") or document.get("error_message") or "")


def api_error(document: dict, conn_id: str = "") -> dict:
    code = str(document.get("error_code") or "unknown")
    message = api_message(document) or code
    return {"code": "plaid." + code, "msg": message[:500], "conn_id": conn_id, "account_id": ""}


def epoch_of(value: object, fallback: int = 0) -> int:
    if isinstance(value, (int, float)) and value > 0:
        return int(value)
    text = str(value or "")
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        if fmt == "%Y-%m-%d":
            parsed = datetime.combine(date.fromisoformat(text), datetime.min.time())
        return int(parsed.replace(tzinfo=parsed.tzinfo or timezone.utc).timestamp())
    return fallback


def account_of(raw: dict, item: dict, now: int) -> dict:
    if not isinstance(raw, dict) or not raw.get("account_id"):
        raise PlaidError("Plaid account has no account_id")
    balances = raw.get("balances") if isinstance(raw.get("balances"), dict) else {}
    currency = balances.get("iso_currency_code") or balances.get("unofficial_currency_code") or "USD"
    conn_id = "plaid-" + item["item_id"]
    return {
        "id": str(raw["account_id"]),
        "name": str(raw.get("name") or raw.get("official_name") or raw["account_id"]),
        "conn_id": conn_id,
        "conn_name": item["institution"],
        "currency": str(currency),
        "balance": money_or_none(balances.get("current")),
        "available_balance": money_or_none(balances.get("available")),
        "balance_date": now,
        "transactions": [],
    }


def money_or_none(value: object) -> str | None:
    if value is None:
        return None
    try:
        return format(Decimal(str(value)), "f")
    except (ArithmeticError, ValueError):
        return None


def transaction_of(raw: dict, now: int) -> dict:
    if not isinstance(raw, dict) or not raw.get("transaction_id"):
        raise PlaidError("Plaid transaction has no transaction_id")
    posted = epoch_of(raw.get("authorized_date") or raw.get("date"), now)
    try:
        # Plaid: positive means money leaving the account. SimpleFIN is the opposite.
        amount = -float(raw.get("amount") or 0)
    except (TypeError, ValueError):
        raise PlaidError("Plaid transaction amount is not numeric") from None
    return {
        "id": str(raw["transaction_id"])[:200],
        "posted": posted,
        "amount": format(Decimal(str(amount)).normalize(), "f"),
        "description": str(raw.get("merchant_name") or raw.get("name") or "")[:500],
        "transacted_at": posted,
        "pending": bool(raw.get("pending")),
        "account_id": str(raw.get("account_id") or ""),
    }


def collect(
    session: dict,
    state: dict,
    *,
    now: int | None = None,
    opener: urllib_request.OpenerDirector | None = None,
) -> tuple[list[dict], list[dict], list[dict]]:
    """Return (normalized accounts, error entries, removed-transaction items)."""
    now = int(now if now is not None else datetime.now(timezone.utc).timestamp())
    plaid_state = state.setdefault("plaid", {})
    accounts: dict[str, dict] = {}
    errors: list[dict] = []
    removed_items: list[dict] = []
    for item in session["items"]:
        entry = plaid_state.setdefault(item["item_id"], {"cursor": ""})
        cursor = str(entry.get("cursor") or "")
        added: list[dict] = []
        modified: list[dict] = []
        removed: list[dict] = []
        item_accounts: list[dict] = []
        next_cursor = cursor
        complete = False
        try:
            for _ in range(MAX_PAGES):
                document = request(
                    session,
                    "/transactions/sync",
                    {"access_token": item["access_token"], "cursor": next_cursor, "count": SYNC_COUNT},
                    opener=opener,
                )
                if document.get("error_code"):
                    errors.append(api_error(document, "plaid-" + item["item_id"]))
                    break
                added.extend(document.get("added") or [])
                modified.extend(document.get("modified") or [])
                removed.extend(document.get("removed") or [])
                for raw in document.get("accounts") or []:
                    item_accounts.append(account_of(raw, item, now))
                next_cursor = str(document.get("next_cursor") or next_cursor)
                if not document.get("has_more"):
                    complete = True
                    break
        except PlaidError as exc:
            errors.append(
                {
                    "code": "plaid.request_failed",
                    "msg": str(exc)[:500],
                    "conn_id": "plaid-" + item["item_id"],
                    "account_id": "",
                }
            )
            continue
        if not complete:
            errors.append(
                {
                    "code": "plaid.page_limit",
                    "msg": "sync did not drain inside the page cap",
                    "conn_id": "plaid-" + item["item_id"],
                    "account_id": "",
                }
            )
            continue
        entry["cursor"] = next_cursor
        entry["synced_at"] = now
        for account in item_accounts:
            accounts.setdefault(account["id"], account)
        for raw in added + modified:
            transaction = transaction_of(raw, now)
            account = accounts.get(transaction["account_id"])
            if account is not None:
                account["transactions"].append(transaction)
        for raw in removed:
            if isinstance(raw, dict) and raw.get("transaction_id"):
                removed_items.append(
                    {
                        "type": "finance-removed",
                        "source": "plaid",
                        "transaction_id": str(raw["transaction_id"]),
                        "account_id": str(raw.get("account_id") or ""),
                    }
                )
    return list(accounts.values()), errors, removed_items


def link_token_create(
    session: dict,
    user_id: str,
    *,
    opener: urllib_request.OpenerDirector | None = None,
) -> str:
    """Human-gated: run once per Item while the owner is in Plaid Link."""
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", user_id):
        raise PlaidError("user id is not a slug")
    document = request(
        session,
        "/link/token/create",
        {
            "client_name": "kanbei",
            "language": "en",
            "country_codes": ["US"],
            "user": {"client_user_id": user_id},
            "products": ["transactions"],
        },
        opener=opener,
    )
    if document.get("error_code") or not document.get("link_token"):
        raise PlaidError(api_message(document) or "Plaid returned no link token")
    return str(document["link_token"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-finance-plaid")
    parser.add_argument("--env", default="/run/ingest-secret/env")
    parser.add_argument("--user", default="owner", help="Link user id")
    parser.add_argument("--link-token", action="store_true", help="create a Link token (human-gated)")
    args = parser.parse_args(argv)
    if not args.link_token:
        parser.error("only --link-token is exposed; the collector calls /transactions/sync itself")
    try:
        with open(args.env, encoding="utf-8") as handle:
            values = {}
            for line in handle.read().splitlines():
                key, sep, value = line.strip().partition("=")
                if sep and key in ENV_KEYS:
                    values[key] = value
        session = session_of(values)
        print(link_token_create(session, args.user))
        return 0
    except (OSError, PlaidError) as exc:
        print(f"ingest-finance-plaid: {exc}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    sys.exit(main())
