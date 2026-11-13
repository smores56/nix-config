# ingest-finance: Schwab and Chase

The `ingest-finance` guest holds one read-only SimpleFIN Access URL and, only
when the owner enables it, one or more Plaid Items. It polls `/accounts` once a
day, renders hledger journals with deterministic account names, and ships them
over the same vsock channel and host writer as every other ingest source
([`docs/kanbei-ingest.md`](kanbei-ingest.md)).

Module: `modules/nixos/ingest-vm.nix` (guest block `lib.mkIf (id == "finance")`).
Table entry: `modules/lib/ingest-vm.nix`. Tools:
`modules/lib/ingest/finance.py` (SimpleFIN, journal rendering) and
`modules/lib/ingest/plaid.py` (fallback client). Tests:
`tests/test_ingest_finance.py`.

## Why SimpleFIN first

SimpleFIN is a read-only protocol: the only credential is an Access URL, no bank
password ever reaches this host, and the institution connection is owned by the
Bridge. Both Schwab and Chase appear in the Bridge's institution list, but they
are reached through MX, whose reliability varies: a connection can silently
return `act.missingdata` or `con.auth` while the bank's own site works. The
collector treats either as an alert and holds the cursor, so the gap is visible
in Kanbei instead of looking like a quiet day. Check the current Bridge
institution list before claiming a token; if an institution is absent or stays
broken, use the Plaid fallback below.

## Access URL (one-time, human)

The Access URL is a bearer credential: it embeds the SimpleFIN username and
password. It is stored only in `/run/secrets/ingest-finance-env` (mode `0400
root:root`), read from the read-only block device, and never logged.

1. In the SimpleFIN Bridge, connect Schwab and Chase and create a SimpleFIN
   Token (the Bridge shows a Base64 token).
2. Claim it on a machine with a terminal (the claim token is one-time; a 403
   means it was already used or leaked — create a new one):

   ```sh
   token='<base64 token>'
   curl -X POST "$(printf '%s' "$token" | base64 -d)"
   # https://owner:password@bridge.simplefin.org/simplefin
   umask 077
   printf 'SIMPLEFIN_ACCESS_URL=%s\n' "$access_url" > finance-env
   ```

3. Stage it as described in [`docs/manual-steps.md`](../docs/manual-steps.md)
   (`sudo install -m 0400 -o root -g root finance-env /run/secrets/ingest-finance-env`,
   then stop the guest and `systemctl start ingest-vm-secret-finance`).

Rotating or revoking access means claiming a new token and re-staging the
device. A revoked URL returns 403; the unit fails and the failure mail says to
re-claim.

### Secret contract

`/run/ingest-secret/env` is strict; any key outside this set fails the unit so a
typo is not silently ignored.

| key | required | meaning |
|---|---|---|
| `SIMPLEFIN_ACCESS_URL` | yes | HTTPS Access URL with Basic credentials |
| `SIMPLEFIN_LOOKBACK_DAYS` | no | first-run backfill (default 90, 1..3650) |
| `SIMPLEFIN_START_DATE` | no | explicit first cursor (epoch seconds) |
| `PLAID_ENABLED` | no | `0` (default) or `1` |
| `PLAID_ENV` | with Plaid | must be `production` |
| `PLAID_CLIENT_ID`, `PLAID_SECRET` | with Plaid | Plaid application credentials |
| `PLAID_ITEMS_JSON` | with Plaid | `[{"item_id","access_token","institution"}]` |

## Protocol handling

One `GET /accounts?version=2&start-date=<epoch>` per run returns every account,
its balance and its transactions; SimpleFIN has no separate transaction
endpoint. The response is parsed as v2 when `connections` or `errlist` is
present, otherwise as v1:

- v2 `connections[]` supplies `conn_name` and `org_url`; `errlist[]` entries are
  `{code,msg,conn_id?,account_id?}`;
- v1 accounts carry an `org` object and the AccountSet carries `errors[]`
  strings, which the collector normalises to `v1.error` alerts (v1 has no
  structured severity).

Error handling:

- `gen.auth` / `gen.api` (and any unknown `gen.*`) are fatal: the unit exits
  non-zero and the writer's failure mail carries the refreshed credential need.
- `con.auth`, `act.failed`, `act.missingdata` and v1 errors are alerts: the
  affected connection/account is excluded from the journal, an `alert` batch is
  sent (the host writer starts the failure mail unit), and the cursor is held so
  the gap is retried.
- Unknown non-`gen` subcodes are treated by prefix, so a new `act.*` code does
  not silently drop data.

The cursor is the epoch of the last successful run in
`/var/lib/finance/state.json`; each request starts three days earlier
(`RETRY_OVERLAP_SECONDS`) so late-posted transactions are picked up. Dedupe is
`sha256(account_id, posted, amount, description)` with the last 10 000 keys
kept, so the overlap and an at-least-once batch replay never double-count. A
run with any alert does not advance the cursor.

## Journals

Each account gets a deterministic path
`assets:bank:<connection>:<account>` (ASCII slug, lowercase, `-` separators;
two same-named accounts get an id suffix). Every posted transaction becomes:

```hledger
2026-01-02 * Uncle Frank's Bait Shop  ; simplefin 0f3c…
    expenses:unknown  USD 33.43
    assets:bank:my-bank-jeff:savings  USD -33.43
```

- SimpleFIN positive means money into the account, so the asset posting is the
  amount and the balancing posting is `income:unknown` for deposits,
  `expenses:unknown` for withdrawals.
- ISO 4217 currencies render as `USD 1.00`; a custom currency URL (miles,
  points) renders as a stable quoted commodity `"ccy-<hash>"`.
- Pending transactions are never requested and are skipped if a server sends
  them anyway.
- Balances are emitted every run as `{"type":"finance-balance",…}` items, so a
  balance moves in Kanbei even on a day with no transactions.
- Journal items are `{"type":"finance-journal","format":"hledger","account",
  "connection","currency","from","to","count","journal"}`; one account-run is
  one item (chunked at 300 transactions / 350 KiB), never a partial journal.

Batch envelopes follow the shared schema (`v`, `source: finance`, `kind`,
`seq`, `sent_at`, `items`) and are written atomically to
`/var/lib/ingest/outbox`.

## Plaid fallback (default off)

Plaid exists for an institution SimpleFIN lacks. It is disabled unless
`ingestVm.financePlaid.enable = true`; that option is the only switch that adds
`production.plaid.com` to the finance allowlist
(`ingest.financeAllow` in the shared table). With it off, the guest's allowlist
is exactly `bridge.simplefin.org`.

The client implements two endpoints:

- `POST /link/token/create` — **human-gated**. The owner runs
  `ingest-finance-plaid --env <secret> --link-token`, completes Plaid Link
  (Chase and Schwab OAuth are Production-only), and writes the Item's
  `access_token` into `PLAID_ITEMS_JSON`. The timer never calls it.
- `POST /transactions/sync` — cursor path. Added and modified transactions are
  fetched until `has_more` is false; `removed` becomes
  `{"type":"finance-removed","transaction_id","account_id"}`; the returned
  `next_cursor` is persisted per Item. A failed Item keeps its old cursor and
  raises `plaid.<error_code>` as an alert (`ITEM_LOGIN_REQUIRED` included).

Plaid's `amount` is positive for money leaving the account, which the collector
flips to SimpleFIN's sign before rendering. Personal-use limits: the Trial plan
allows 10 production Items, and an OAuth institution is approved per Item; a
new institution needs a new Item and the owner in the loop. No Plaid traffic
exists unless the option and the contract are both set.

## Units and limits

| unit | purpose |
|---|---|
| `ingest-finance.service` | one `/accounts` poll, journal/balance batches, alert batch |
| `ingest-finance.timer` | daily at 06:17 with up to 30 min jitter, `Persistent=true` |

`MemoryHigh=96M`, `MemoryMax=160M`; the guest is 256 MiB (the boot floor — the
68 MiB initramfs does not fit in less). The timer is
`Restart`-free by design (a failed run waits for the next day or the manual
`systemctl start`). Freshness is the table's 36 h window: one missed daily run
plus a retry is silent, two are a page.

## Verification

```sh
nix build .#checks.x86_64-linux.unit-tests .#checks.x86_64-linux.kanbei-ingest-guards
nix eval .#nixosConfigurations.smortress --apply 'c: (c.extendModules { modules = [ ({ lib, ... }: { ingestVm.enable = lib.mkForce true; kanbeiVm.enable = lib.mkForce true; }) ]; }).config.microvm.vms.ingest-finance.config.config.system.build.toplevel.drvPath'
```

Hardware/credential gated (root on smortress, a real SimpleFIN account):

1. Stage `ingest-finance-env`, start `microvm@ingest-finance`, and check
   `systemctl status ingest-finance` inside the guest.
2. `sudo cat /var/lib/kanbei-ingest/state/finance.last-ok` and look for
   `finance-*.age` in `/var/lib/data/inbox`.
3. In Kanbei, confirm both institutions' accounts and journals; a first run
   backfills 90 days, later runs only the overlap.
4. For Plaid: enable the option, re-stage the contract, run the link-token
   command with the owner, complete Link, and confirm `/transactions/sync`
   cursors appear under `plaid` in `/var/lib/finance/state.json`.
