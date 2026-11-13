"""SimpleFIN collector for the `ingest-finance` guest (smores56/sdlc#590).

One `/accounts` request per run returns every account, its balance and the
transactions since the cursor; there is no separate transaction endpoint in
either protocol version. The collector renders hledger journals with
deterministic account names, dedupes by account+posted+amount+description, and
writes NDJSON batches into `/var/lib/ingest/outbox` for `ingest-emit`.

The Access URL is a bearer credential: it carries the SimpleFIN username and
password. It is read only from the read-only secret device, never written to
state, and every log line and error string is passed through `redact_text`.

Protocol v2 (2026-03-19) adds `connections[]` and the structured `errlist`;
v1 responses (`errors[]`, an `org` object on each account) are still parsed, so
a server that ignores `version=2` does not break the feed. Plaid is the fallback
for institutions SimpleFIN cannot reach; it lives in `plaid.py`, is disabled by
default, and its item setup needs the owner.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import unicodedata
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Callable
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

import policy

import plaid

SOURCE = "finance"
STATE_VERSION = 1
PROTOCOL_VERSION = 1
DEFAULT_LOOKBACK_DAYS = 90
# Late-posted transactions are re-fetched inside this overlap and deduped.
RETRY_OVERLAP_SECONDS = 3 * 86400
TXN_KEY_KEEP = 10000
MAX_ITEMS_PER_BATCH = 300
MAX_BATCH_BYTES = 350_000
MAX_RESPONSE_BYTES = 8 << 20
MAX_ERROR_TEXT = 500
ENV_KEYS = {
    "SIMPLEFIN_ACCESS_URL",
    "SIMPLEFIN_LOOKBACK_DAYS",
    "SIMPLEFIN_START_DATE",
    "PLAID_ENABLED",
    "PLAID_ENV",
    "PLAID_CLIENT_ID",
    "PLAID_SECRET",
    "PLAID_ITEMS_JSON",
}
FATAL_ERROR_CODES = {"gen.auth", "gen.api"}
ISO_CURRENCY = re.compile(r"^[A-Z]{3}$")
_SECRETS: set[str] = set()


class FinanceError(RuntimeError):
    """A refused secret, document, transaction or state file."""


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-finance", "event": event}
    record.update({key: sanitize(value) for key, value in fields.items()})
    print(redact_text(json.dumps(record, sort_keys=True)), flush=True)


def sanitize(value: object) -> object:
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if isinstance(value, dict):
        return {key: sanitize(item) for key, item in value.items()}
    return value


def register_secrets(*values: str) -> None:
    for value in values:
        if value:
            _SECRETS.add(value)


def redact_url(url: str) -> str:
    """Return scheme://host[:port]/path: no userinfo, query or fragment."""
    try:
        parts = urllib_parse.urlsplit(url)
    except ValueError:
        return "<redacted>"
    if not parts.hostname:
        return "<redacted>"
    port = f":{parts.port}" if parts.port else ""
    return f"{parts.scheme}://{parts.hostname}{port}{parts.path}"


def redact_text(text: str) -> str:
    out = str(text)
    for secret in sorted(_SECRETS, key=len, reverse=True):
        out = out.replace(secret, "[redacted]")
    # Any remaining `://user:pass@host` form, e.g. an exception from urllib.
    out = re.sub(r"(?<=://)[^/@\s]+@", "[redacted]@", out)
    return out


def parse_env(text: str) -> dict[str, str]:
    """Parse the strict KEY=value secret contract; duplicates and junk are refused."""
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise FinanceError(f"secret line {number} is not KEY=value")
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise FinanceError(f"secret line {number} has a non-contract key")
        if value[:1] == value[-1:] and value[:1] in ("'", '"') and len(value) >= 2:
            value = value[1:-1]
        if key in values:
            raise FinanceError(f"secret key {key} appears twice")
        values[key] = value
    return values


def validate_access_url(url: str) -> str:
    if not isinstance(url, str) or not url:
        raise FinanceError("SIMPLEFIN_ACCESS_URL is missing")
    try:
        parts = urllib_parse.urlsplit(url)
    except ValueError as exc:
        raise FinanceError("SIMPLEFIN_ACCESS_URL is not a URL") from None
    if parts.scheme != "https":
        raise FinanceError("SIMPLEFIN_ACCESS_URL must be HTTPS")
    if not parts.hostname:
        raise FinanceError("SIMPLEFIN_ACCESS_URL has no host")
    if not parts.username or not parts.password:
        raise FinanceError("SIMPLEFIN_ACCESS_URL must carry the claim's Basic credentials")
    if parts.fragment:
        raise FinanceError("SIMPLEFIN_ACCESS_URL has a fragment")
    return url.rstrip("/")


def session_of(env: dict[str, str]) -> dict:
    unknown = set(env) - ENV_KEYS
    if unknown:
        raise FinanceError(f"unknown secret keys: {sorted(unknown)}")
    access_url = validate_access_url(env.get("SIMPLEFIN_ACCESS_URL", ""))
    register_secrets(access_url)
    session: dict = {
        "access_url": access_url,
        "lookback_days": DEFAULT_LOOKBACK_DAYS,
        "start_date": None,
        "plaid": None,
    }
    if "SIMPLEFIN_LOOKBACK_DAYS" in env:
        try:
            lookback = int(env["SIMPLEFIN_LOOKBACK_DAYS"])
        except ValueError:
            raise FinanceError("SIMPLEFIN_LOOKBACK_DAYS is not an integer") from None
        if not 1 <= lookback <= 3650:
            raise FinanceError("SIMPLEFIN_LOOKBACK_DAYS must be 1..3650")
        session["lookback_days"] = lookback
    if env.get("SIMPLEFIN_START_DATE"):
        try:
            start = int(env["SIMPLEFIN_START_DATE"])
        except ValueError:
            raise FinanceError("SIMPLEFIN_START_DATE is not an epoch timestamp") from None
        if start <= 0:
            raise FinanceError("SIMPLEFIN_START_DATE must be positive")
        session["start_date"] = start
    enabled = env.get("PLAID_ENABLED", "0")
    if enabled not in ("0", "1"):
        raise FinanceError("PLAID_ENABLED must be 0 or 1")
    if enabled == "1":
        try:
            session["plaid"] = plaid.session_of(env)
        except plaid.PlaidError as exc:
            raise FinanceError(str(exc)) from None
    return session


def credential_free_netloc(parts: urllib_parse.SplitResult) -> str:
    host = parts.hostname or ""
    return f"{host}:{parts.port}" if parts.port else host


def auth_header(access_url: str) -> str:
    """The claim's Basic credentials as a header.

    urllib hands the URL's userinfo to the proxy tunnel, which parses it as a
    `host:port` and dies with `InvalidURL: nonnumeric port` — the access URL always
    carries credentials, so they have to travel as a header instead.
    """
    parts = urllib_parse.urlsplit(access_url)
    user = urllib_parse.unquote(parts.username or "")
    password = urllib_parse.unquote(parts.password or "")
    token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def accounts_url(access_url: str, start_date: int | None, version: int = 2) -> str:
    parts = urllib_parse.urlsplit(access_url)
    query = {"version": str(version)}
    if start_date is not None:
        query["start-date"] = str(int(start_date))
    return urllib_parse.urlunsplit(
        (
            parts.scheme,
            credential_free_netloc(parts),
            parts.path.rstrip("/") + "/accounts",
            urllib_parse.urlencode(query),
            "",
        )
    )


def http_json(
    url: str,
    *,
    auth: str | None = None,
    opener: urllib_request.OpenerDirector | None = None,
    timeout: float = 60.0,
    max_bytes: int = MAX_RESPONSE_BYTES,
) -> object:
    """GET one JSON document; errors never echo the URL's credentials."""
    open_url: Callable[..., object] = (opener or urllib_request.build_opener()).open
    headers = {"Accept": "application/json", "User-Agent": policy.USER_AGENT}
    if auth:
        headers["Authorization"] = auth
    request = urllib_request.Request(url, headers=headers)
    try:
        with open_url(request, timeout=timeout) as response:
            body = response.read(max_bytes + 1)
    except urllib_error.HTTPError as exc:
        code = int(exc.code)
        if code == 403:
            raise FinanceError("SimpleFIN refused the credentials (403): re-claim the access URL") from None
        if code == 402:
            raise FinanceError("SimpleFIN reports payment required (402)") from None
        raise FinanceError(f"SimpleFIN returned HTTP {code}") from None
    except (urllib_error.URLError, OSError, ValueError) as exc:
        raise FinanceError(redact_text(f"SimpleFIN request failed: {exc}")) from None
    if len(body) > max_bytes:
        raise FinanceError("SimpleFIN response exceeds the size cap")
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise FinanceError("SimpleFIN response is not JSON") from None


def decimal_amount(value: object) -> Decimal:
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise FinanceError("amount is not numeric") from None
    if not amount.is_finite():
        raise FinanceError("amount is not finite")
    return amount


def normalize_amount(value: object) -> str:
    return format(decimal_amount(value).normalize(), "f")


def safe_text(value: object) -> str:
    """Collapse control characters and whitespace so a journal line stays one line."""
    text = "".join(ch if ch.isprintable() else " " for ch in str(value or ""))
    return re.sub(r"\s+", " ", text).strip()


def transaction_of(raw: object, account_id: str) -> dict:
    if not isinstance(raw, dict):
        raise FinanceError(f"account {account_id}: transaction is not an object")
    try:
        posted = int(raw.get("posted"))
    except (TypeError, ValueError):
        raise FinanceError(f"account {account_id}: transaction has no posted timestamp") from None
    if posted < 0:
        raise FinanceError(f"account {account_id}: transaction has a negative posted timestamp")
    transacted_at = raw.get("transacted_at")
    if transacted_at is not None:
        try:
            transacted_at = int(transacted_at)
        except (TypeError, ValueError):
            transacted_at = None
    return {
        "id": safe_text(raw.get("id"))[:200],
        "posted": posted,
        "amount": normalize_amount(raw.get("amount")),
        "description": safe_text(raw.get("description"))[:500],
        "transacted_at": transacted_at,
        "pending": bool(raw.get("pending")),
    }


def account_of(raw: object, connections: dict[str, dict]) -> dict:
    if not isinstance(raw, dict):
        raise FinanceError("account entry is not an object")
    account_id = safe_text(raw.get("id"))
    if not account_id:
        raise FinanceError("account has no id")
    org = raw.get("org") if isinstance(raw.get("org"), dict) else {}
    conn_id = safe_text(raw.get("conn_id") or org.get("id") or "")
    conn_name = safe_text(raw.get("conn_name") or org.get("name") or "")
    if not conn_id:
        conn_id = "conn-" + hashlib.sha256(conn_name.encode()).hexdigest()[:12]
    connections.setdefault(
        conn_id,
        {
            "conn_id": conn_id,
            "name": conn_name or conn_id,
            "org_id": safe_text(org.get("id")),
            "org_url": safe_text(raw.get("org_url") or org.get("url")),
        },
    )
    try:
        balance = normalize_amount(raw.get("balance")) if raw.get("balance") is not None else None
    except FinanceError:
        balance = None
    available = raw.get("available-balance", raw.get("available_balance"))
    try:
        available_balance = normalize_amount(available) if available is not None else None
    except FinanceError:
        available_balance = None
    balance_date = raw.get("balance-date", raw.get("balance_date"))
    try:
        balance_date = int(balance_date) if balance_date is not None else None
    except (TypeError, ValueError):
        balance_date = None
    transactions = raw.get("transactions") or []
    if not isinstance(transactions, list):
        raise FinanceError(f"account {account_id}: transactions is not a list")
    return {
        "id": account_id,
        "name": safe_text(raw.get("name")) or account_id,
        "conn_id": conn_id,
        "conn_name": connections[conn_id]["name"],
        "currency": safe_text(raw.get("currency")) or "USD",
        "balance": balance,
        "available_balance": available_balance,
        "balance_date": balance_date,
        "transactions": [transaction_of(txn, account_id) for txn in transactions],
    }


def error_entry(raw: object, v1: bool = False) -> dict:
    if v1:
        return {
            "code": "v1.error",
            "msg": safe_text(raw)[:MAX_ERROR_TEXT],
            "conn_id": "",
            "account_id": "",
        }
    if not isinstance(raw, dict):
        raise FinanceError("errlist entry is not an object")
    code = safe_text(raw.get("code"))
    if not code:
        raise FinanceError("errlist entry has no code")
    return {
        "code": code[:100],
        "msg": safe_text(raw.get("msg"))[:MAX_ERROR_TEXT],
        "conn_id": safe_text(raw.get("conn_id"))[:200],
        "account_id": safe_text(raw.get("account_id"))[:200],
    }


def parse_account_set(document: object) -> dict:
    """Normalize a v2 AccountSet or a v1 response into one shape."""
    if not isinstance(document, dict):
        raise FinanceError("SimpleFIN response is not an object")
    v2 = "connections" in document or "errlist" in document
    if v2:
        if not isinstance(document.get("errlist"), list):
            raise FinanceError("v2 response has no errlist list")
        if not isinstance(document.get("connections"), list):
            raise FinanceError("v2 response has no connections list")
    elif "errors" in document and not isinstance(document["errors"], list):
        raise FinanceError("v1 response has a non-list errors field")
    accounts = document.get("accounts")
    if not isinstance(accounts, list):
        raise FinanceError("SimpleFIN response has no accounts list")
    connections: dict[str, dict] = {}
    if v2:
        for raw in document["connections"]:
            if not isinstance(raw, dict) or not safe_text(raw.get("conn_id")):
                raise FinanceError("v2 connection has no conn_id")
            conn_id = safe_text(raw["conn_id"])
            connections[conn_id] = {
                "conn_id": conn_id,
                "name": safe_text(raw.get("name")) or conn_id,
                "org_id": safe_text(raw.get("org_id")),
                "org_url": safe_text(raw.get("org_url")),
            }
    normalized = [account_of(raw, connections) for raw in accounts]
    errors = (
        [error_entry(raw) for raw in document["errlist"]]
        if v2
        else [error_entry(raw, v1=True) for raw in document.get("errors") or []]
    )
    return {
        "version": 2 if v2 else 1,
        "connections": connections,
        "accounts": normalized,
        "errors": errors,
    }


def is_fatal(error: dict) -> bool:
    code = str(error.get("code", ""))
    if code in FATAL_ERROR_CODES:
        return True
    prefix = code.partition(".")[0]
    # An unknown `gen.*` code is the server saying the API use itself is wrong.
    return prefix == "gen"


def error_scope(parsed: dict, error: dict) -> set[str]:
    """Account ids an error covers: its account, its connection, or every account."""
    account_id = error.get("account_id")
    if account_id:
        return {account_id}
    conn_id = error.get("conn_id")
    if conn_id:
        return {account["id"] for account in parsed["accounts"] if account["conn_id"] == conn_id}
    return {account["id"] for account in parsed["accounts"]}


def transaction_key(account_id: str, posted: int, amount: object, description: object) -> str:
    raw = "\x1f".join(
        [str(account_id), str(int(posted)), normalize_amount(amount), safe_text(description)]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def slug(value: object, *, fallback: str = "unknown") -> str:
    text = unicodedata.normalize("NFKD", str(value or "")).encode("ascii", "ignore").decode()
    text = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if not text:
        return fallback
    if text[0].isdigit():
        text = "a" + text
    return text[:40]


def account_path(conn_name: str, account_name: str, account_id: str) -> str:
    return f"assets:bank:{slug(conn_name)}:{slug(account_name, fallback=slug(account_id))}"


def unique_paths(accounts: list[dict]) -> dict[str, str]:
    """Deterministic account paths; a collision gets the account id suffix."""
    paths: dict[str, str] = {}
    counts: dict[str, int] = {}
    for account in sorted(accounts, key=lambda item: item["id"]):
        path = account_path(account["conn_name"], account["name"], account["id"])
        counts[path] = counts.get(path, 0) + 1
        paths[account["id"]] = path
    for account in accounts:
        path = paths[account["id"]]
        if counts[path] > 1:
            paths[account["id"]] = f"{path}-{slug(account['id'])}"
    return paths


def commodity(currency: str) -> str:
    if ISO_CURRENCY.match(currency):
        return currency
    return '"ccy-' + hashlib.sha256(currency.encode()).hexdigest()[:8] + '"'


def money(amount: object, currency: str) -> str:
    value = decimal_amount(amount)
    if value.as_tuple().exponent < -2:
        rendered = format(value, "f")
    else:
        rendered = format(value.quantize(Decimal("0.01")), "f")
    return f"{commodity(currency)} {rendered}"


def journal_date(txn: dict) -> str:
    posted = txn["posted"] or txn.get("transacted_at") or 0
    return datetime.fromtimestamp(posted, timezone.utc).strftime("%Y-%m-%d")


def render_transaction(txn: dict, asset_path: str, currency: str, key: str) -> str:
    payee = txn["description"].replace(";", ",") or "unknown"
    amount = decimal_amount(txn["amount"])
    counter = "income:unknown" if amount >= 0 else "expenses:unknown"
    return "\n".join(
        [
            f"{journal_date(txn)} * {payee}  ; simplefin {key[:16]}",
            f"    {counter}  {money(-amount, currency)}",
            f"    {asset_path}  {money(amount, currency)}",
            "",
        ]
    )


def render_journal(account: dict, path: str, transactions: list[dict]) -> str:
    header = (
        f"; simplefin account {account['id']} ({account['name']}) "
        f"connection {account['conn_name']} {account['currency']}\n"
    )
    body = "".join(
        render_transaction(
            txn,
            path,
            account["currency"],
            transaction_key(account["id"], txn["posted"], txn["amount"], txn["description"]),
        )
        for txn in sorted(transactions, key=lambda item: (item["posted"], item["id"]))
    )
    return header + body


def balance_item(account: dict, path: str) -> dict:
    return {
        "type": "finance-balance",
        "account": path,
        "account_id": account["id"],
        "connection": account["conn_name"],
        "currency": account["currency"],
        "balance": account["balance"],
        "available_balance": account["available_balance"],
        "balance_date": account["balance_date"],
    }


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {"version": STATE_VERSION, "seq": 0, "cursor": 0, "txn_keys": [], "plaid": {}}
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise FinanceError(f"state file {path} is not JSON") from None
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise FinanceError(f"state file {path} has an unsupported version")
    state.setdefault("seq", 0)
    state.setdefault("cursor", 0)
    state.setdefault("txn_keys", [])
    state.setdefault("plaid", {})
    return state


def write_state(path: str, state: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".finance-state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def chunk_items(items: list[dict], max_items: int = MAX_ITEMS_PER_BATCH, max_bytes: int = MAX_BATCH_BYTES):
    chunk: list[dict] = []
    size = 2
    for item in items:
        encoded = len(json.dumps(item, sort_keys=True).encode("utf-8")) + 2
        if chunk and (len(chunk) >= max_items or size + encoded > max_bytes):
            yield chunk
            chunk = []
            size = 2
        if encoded + 2 > max_bytes:
            raise FinanceError("one item exceeds the batch size cap")
        chunk.append(item)
        size += encoded
    if chunk:
        yield chunk


def write_batch(outbox: str, state: dict, kind: str, items: list[dict]) -> str:
    if kind not in ("batch", "alert"):
        raise FinanceError(f"unknown batch kind {kind}")
    seq = int(state.get("seq", 0)) + 1
    envelope = {
        "v": PROTOCOL_VERSION,
        "source": SOURCE,
        "kind": kind,
        "seq": seq,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": items,
    }
    payload = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(payload) > MAX_BATCH_BYTES + 2048:
        raise FinanceError("batch exceeds the size cap")
    os.makedirs(outbox, mode=0o700, exist_ok=True)
    name = f"{seq:06d}-{kind}-{int(time.time())}.json"
    fd, temporary = tempfile.mkstemp(dir=outbox, prefix=".batch-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, os.path.join(outbox, name))
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    state["seq"] = seq
    return name


def render_accounts(
    accounts: list[dict], seen: set[str], excluded: set[str]
) -> tuple[list[dict], list[dict], list[str], int]:
    """Turn normalized accounts into journal/balance items, deduping in `seen`."""
    paths = unique_paths(accounts)
    journal_items: list[dict] = []
    balance_items: list[dict] = []
    new_keys: list[str] = []
    emitted = 0
    for account in accounts:
        path = paths[account["id"]]
        balance_items.append(balance_item(account, path))
        if account["id"] in excluded:
            continue
        fresh = []
        for txn in account["transactions"]:
            if txn["pending"]:
                continue
            key = transaction_key(account["id"], txn["posted"], txn["amount"], txn["description"])
            if key in seen:
                continue
            seen.add(key)
            new_keys.append(key)
            fresh.append(txn)
        if not fresh:
            continue
        for chunk in chunk_items(fresh):
            journal_items.append(
                {
                    "type": "finance-journal",
                    "format": "hledger",
                    "account": path,
                    "account_id": account["id"],
                    "connection": account["conn_name"],
                    "currency": account["currency"],
                    "from": journal_date(min(chunk, key=lambda item: item["posted"])),
                    "to": journal_date(max(chunk, key=lambda item: item["posted"])),
                    "count": len(chunk),
                    "journal": render_journal(account, path, chunk),
                }
            )
        emitted += len(fresh)
    return journal_items, balance_items, new_keys, emitted


def collect(
    session: dict,
    state: dict,
    outbox: str,
    *,
    opener: urllib_request.OpenerDirector | None = None,
    now: int | None = None,
) -> dict:
    """Fetch, render and persist one run. Returns a summary for tests and logs."""
    now = int(now if now is not None else time.time())
    cursor = int(state.get("cursor") or 0)
    if cursor:
        start = max(0, cursor - RETRY_OVERLAP_SECONDS)
    elif session.get("start_date"):
        start = int(session["start_date"])
    else:
        start = now - int(session.get("lookback_days", DEFAULT_LOOKBACK_DAYS)) * 86400
    url = accounts_url(session["access_url"], start)
    document = http_json(url, auth=auth_header(session["access_url"]), opener=opener)
    parsed = parse_account_set(document)
    state["protocol"] = parsed["version"]
    log("accounts", protocol=parsed["version"], count=len(parsed["accounts"]), host=redact_url(url))

    alerts = list(parsed["errors"])
    fatal = any(is_fatal(error) for error in alerts)
    excluded: set[str] = set()
    for error in alerts:
        if not is_fatal(error):
            excluded |= error_scope(parsed, error)

    seen = set(str(key) for key in state.get("txn_keys", []))
    journal_items, balance_items, new_keys, emitted = render_accounts(
        parsed["accounts"], seen, excluded
    )

    plaid_errors: list[dict] = []
    plaid_removed: list[dict] = []
    plaid_count = 0
    if session.get("plaid"):
        plaid_accounts, plaid_errors, plaid_removed = plaid.collect(
            session["plaid"], state, now=now, opener=opener
        )
        extra_journals, extra_balances, extra_keys, plaid_count = render_accounts(
            plaid_accounts, seen, set()
        )
        journal_items.extend(extra_journals)
        balance_items.extend(extra_balances)
        new_keys.extend(extra_keys)
        emitted += plaid_count
        alerts.extend(plaid_errors)
        journal_items.extend(plaid_removed)

    if alerts:
        alert_items = [
            {
                "type": "finance-error",
                "code": error["code"],
                "message": error["msg"],
                "connection": error.get("conn_id", ""),
                "account": error.get("account_id", ""),
                "fatal": is_fatal(error),
            }
            for error in alerts
        ]
        write_batch(outbox, state, "alert", alert_items)

    for chunk in chunk_items(journal_items):
        write_batch(outbox, state, "batch", chunk)
    for chunk in chunk_items(balance_items):
        write_batch(outbox, state, "batch", chunk)

    if alerts:
        # Hold the cursor: a failed institution or incomplete listing must be
        # retried inside the overlap, and dedupe keeps the replay harmless.
        log("held", reason="upstream errors", errors=len(alerts))
    else:
        state["cursor"] = now
    state["txn_keys"] = sorted(set(state.get("txn_keys", [])) | set(new_keys))[-TXN_KEY_KEEP:]
    return {
        "protocol": parsed["version"],
        "accounts": len(parsed["accounts"]),
        "transactions": emitted,
        "journals": len(journal_items),
        "alerts": len(alerts),
        "fatal": fatal,
        "start": start,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-finance")
    parser.add_argument("--env", default="/run/ingest-secret/env")
    parser.add_argument("--outbox", default="/var/lib/ingest/outbox")
    parser.add_argument("--state", default="/var/lib/finance/state.json")
    args = parser.parse_args(argv)
    try:
        with open(args.env, encoding="utf-8") as handle:
            env = parse_env(handle.read())
        session = session_of(env)
        state = load_state(args.state)
        summary = collect(session, state, args.outbox)
        write_state(args.state, state)
        log("done", **summary)
        # A fatal `gen.*` refusal also fails the unit; the alert batch already
        # started the failure mail, so the journal carries the exact code.
        return 2 if summary.get("fatal") else 0
    except (OSError, FinanceError, plaid.PlaidError) as exc:
        log("error", reason=str(exc))
        return 65


if __name__ == "__main__":
    sys.exit(main())
