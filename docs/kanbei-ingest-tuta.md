# ingest-tuta: mail and calendar

The `ingest-tuta` guest is the only component that holds the owner's Tuta
session. It runs TutaBridge on loopback, collects new mail over IMAP, renders
calendar changes as ICS, and ships every batch over the same vsock channel and
host writer as the other ingest sources
([`docs/kanbei-ingest.md`](kanbei-ingest.md)).

Module: `modules/nixos/ingest-vm.nix` (guest block `lib.mkIf (id == "tuta")`).
Table entry: `modules/lib/ingest-vm.nix`. Tools:
`modules/lib/ingest/tuta_session.py`, `tuta_mail.py`, `tuta_ics.py`. Bridge
package: `pkgs/tutabridge.nix`. Calendar crate: `pkgs/tuta-ics`.

## Why a bridge at all

Tuta has no HTTP API and no calendar subscription, and the owner's mail is
end-to-end encrypted. TutaBridge (`github.com/spartanz51/tutabridge`) embeds
Tuta's own Rust SDK, so decryption happens on this machine, and exposes the
account as an IMAP/SMTP server on loopback. Tuta does not endorse it; the guest
is sized and network-scoped as a data tier for exactly that reason. Gmail
arrives through the owner's forward into Tuta, so there is no second mail
source.

TutaBridge is pinned to one release binary (`0.2.0-rc.2`) and verified by
SHA256 from the release's `SHA256SUMS`; a source build needs the patched SDK
preparation (`scripts/sdk-prepare.py`), which is not reproduced in Nix. The
release binary is unpacked and patched with `autoPatchelfHook` (glibc, libgcc,
libdbus). `nix build` fails the guest if the hash or a runtime library drifts.

## Session bootstrap (one-time, human)

The bridge's session is a `pass` entry encrypted with a dedicated GPG key. The
Firecracker guest has one read-only secret file, so the whole session is
carried as one base64 tar.gz value.

1. On a machine with a terminal (not in the guest), in a throwaway directory:

   ```sh
   export XDG_CONFIG_HOME=$PWD/config XDG_CACHE_HOME=$PWD/cache \
          GNUPGHOME=$PWD/gnupg PASSWORD_STORE_DIR=$PWD/pass \
          TUTABRIDGE_RUNTIME_DIR=$PWD/run
   umask 077
   tutabridge init            # address, password, TOTP if the account uses it
   tutabridge password        # the bridge password the collector logs in with
   tar -C "$PWD" -czf session.tar.gz gnupg pass config
   base64 -w0 session.tar.gz > session.b64
   shred -u session.tar.gz
   ```

   `init` keeps the session in `pass` at `tuta/bridge/<address>`; the GPG key
   has no passphrase so the guest can resume unattended. The Tuta password is
   never saved and never goes into the secret file; only the encrypted session,
   the GPG key that opens it, the bridge password and the address do.

2. Write `/run/secrets/ingest-tuta-env` (mode `0400 root:root`) with:

   ```
   TUTA_ADDRESS=owner@tuta.com
   TUTA_SESSION_B64=<contents of session.b64>
   TUTA_BRIDGE_PASSWORD=<the bridge password, unless config.toml carries it>
   TUTA_PASS_PATH=tuta/bridge        # optional, this is the default
   TUTA_TOTP_SECRET=<base32 seed>    # optional, only for the next one-time login
   ```

   `ingest-vm-secret-tuta.service` seals it into the read-only image; the guest
   reads `/run/ingest-secret/env`. Keys outside this set are refused, so a
   mistyped name fails the session unit instead of being ignored.

3. Rotate by repeating step 1 and re-staging the image (stop the guest first;
   the secret unit refuses to replace a live image).

The session unit `tutabridge-session.service` (oneshot, before the bridge)
extracts only `gnupg/`, `pass/` and `config/` with a traversal and symlink
guard, rewrites `config.toml` (loopback bind, ports 1143/1025, `pass_path`,
`sync_limit = 50`, MCP disabled) and writes the address and bridge password to
`/run/tutabridge/` at `0600`. Nothing is echoed: the tool logs key names only.

## Guest units

| unit | purpose |
|---|---|
| `tutabridge-session.service` | seed the session and loopback credentials from the secret image |
| `tutabridge.service` | `tutabridge run --wait`, loopback IMAP 1143 / SMTP 1025, restart always |
| `ingest-tuta-mail.service` | IMAP collector, writes NDJSON batches to `/var/lib/ingest/outbox` |
| `ingest-tuta-ics.timer` + `.service` | every 30 minutes, render calendar changes or report the missing fetcher |

SMTP is bound to `127.0.0.1` and is never in the guest firewall's allowed
ports; the collector uses IMAP only and `BODY.PEEK[]`, so it never marks a
message read. The bridge's cache and session live in the guest's tmpfs
(`/var/lib/tutabridge`) and are rebuilt from the secret image at every boot;
`sync_limit = 50` bounds the body cache, and the bridge unit's
`MemoryHigh=180M`/`MemoryMax=240M` keep a runaway sync from taking the guest
down. An account with a very large mailbox may need the table's 256 MiB bumped.

## Egress

Unchanged from the shared table: the guest may reach exactly `app.tuta.com`
through the host proxy (`10.77.10.1:3128`) and that name through the allowlist
resolver. `HTTPS_PROXY` is set in the guest environment, which the bridge's HTTP
client honours. No other name, IP, LAN address or other VM tap is reachable; the
per-tap forward chain ends in DROP and the guest repeats the policy on its own
OUTPUT chain.

## Mail collector

`ingest-tuta-mail` connects to `127.0.0.1:1143` (self-signed certificate on
loopback, so hostname verification is off by design) and:

- lists folders, always collecting `INBOX` and the folder classified as Sent,
  plus any names passed with `--folders`;
- waits in `IMAP IDLE` once per pass (capped at 120 s, far inside the
  29-minute server window) and falls back to `UID SEARCH` when the server lacks
  IDLE; a full pass runs every `--poll-seconds` (default 300);
- keeps one JSON state file (`/var/lib/tutabridge/mail-state.json`, `0600`):
  per-folder `UIDVALIDITY` and the last 2000 UIDs, a batch sequence counter, the
  bridge-log offset and alert timestamps;
- baselines a folder it has never seen instead of replaying the whole mailbox;
- re-baselines without emitting when `UIDVALIDITY` changes, because old ids now
  name different messages;
- caps each item's text body at 64 KiB (text/plain preferred, HTML stripped;
  attachments are never fetched), 50 items and 512 KiB per batch, and refuses an
  item that alone exceeds the cap;
- writes each chunk as `NNNNNN-<kind>-<epoch>.json` with `fsync` + rename, then
  advances the sequence. Crash between write and state save re-emits a batch;
  Kanbei dedupes on `Message-ID`, so the protocol is at-least-once.

Items are `{"type":"mail","folder","uid","date","from","to","subject",
"message_id","body"}`. No attachment bytes, no headers beyond those five, and no
password or address in any log line.

### Alerts

Two signals are sent as `kind = "alert"` batches. The host writer validates the
same schema, encrypts them like any batch, and starts
`ntfy-publish@ingest-writer-tuta.service`, which is the same failure mail
path a broken unit uses.

- **New Sent item.** Every message that appears in the Sent folder produces one
  `sent-alert` item (no body). The session is send-capable, so this is the
  tamper signal: anything sent from the account is reported immediately.
- **Tuta client rejection.** The collector tails the bridge's own log
  (`/var/lib/tutabridge/bridge.log`, root-only) and matches `Tuta rejects this
  version` (`minimum-client`) and `Saved session rejected`
  (`session-rejected`). Each reason alerts at most once per 24 h. A
  `minimum-client` rejection means Tuta raised its floor: bump TutaBridge (see
  below). `session-rejected` means the session no longer decrypts or was
  revoked: repeat the one-time login.

Transient lines (`Tuta temporarily unavailable; retrying with backoff`) are
bridge-internal retries and do not page. The heartbeat still catches the case
where the bridge never recovers, because no batch arrives.

## Calendar

`pkgs/tuta-ics` is a small Rust crate. It has three parts:

- a strict event model and parser (`src/lib.rs`) that refuses unknown keys,
  non-UTC instants, bad all-day dates and unknown statuses;
- an RFC 5545 renderer with escaping, 75-octet line folding, deterministic
  ordering and a stable FNV-1a fingerprint;
- a feature-gated SDK fetcher (`src/sdk.rs`) that lists calendar groups and
  events and maps them onto the model.

`src/sdk.rs` contains no create, update or delete call, so no build of this
crate can write to Tuta. The parsers and renderer are covered by Rust unit
tests, and `nix build .#tuta-ics` runs them.

**The SDK fetcher does not build in this environment.** It links `tutanota`'s
Rust SDK through TutaBridge's *prepared* SDK: a pinned tutanota submodule plus
the patch series from `scripts/sdk-prepare.py` (the AEAD session/group reads
calendar bodies need), bindgen and the generated entity tree. None of that is in
this repository or the Nix sandbox, and the crate deliberately carries no SDK
path so the lockfile stays vendorable. `nix build .#tuta-ics-sdk` is marked
broken and fails at the unresolved `tutanota` import. That gap is recorded here
rather than hidden:

- `ingest-tuta-ics.timer` still runs every 30 minutes. Without an event export
  it emits one `calendar-unavailable` alert batch per day, so the calendar
  appears as an open alert in Kanbei instead of a quietly empty calendar.
- When the SDK build lands, the fetcher writes
  `/var/lib/tutabridge/calendar/events.json` (the neutral export shape in
  `src/lib.rs` tests). The timer picks it up on the next run, renders ICS with
  `tuta-ics --input ... --out ...`, and emits a `{"type":"calendar","format":
  "ics","fingerprint":...,"ics":...}` batch only when the fingerprint changed.
  No unit change is needed; only the fetcher binary and the JSON export.

ICS limits: one batch cap (1 MiB), an ICS file cap of 512 KiB, and at most 5000
events per export. Recurring events are rendered as the SDK's expanded
instances; the crate does not implement `RRULE`. Calendar names are carried as
`X-WR-CALNAME` and every event keeps its `UID`, so Kanbei can reconcile across
renders.

## Tuta client bumps

Tuta only accepts clients above a moving minimum version, and TutaBridge
announces the SDK version it embeds. The flow when the owner gets a
`minimum-client` alert:

1. Pick the newest TutaBridge release and read its `SHA256SUMS`.
2. Update `version` and `hash` in `pkgs/tutabridge.nix` (one place; the Linux
   CLI asset is `tutabridge-linux-x86_64`).
3. `nix build` the guest, then restart it: `systemctl restart
   microvm@ingest-tuta` (the guest's own units restart inside it).
4. If the bridge's config keys changed, update the session unit's
   `render_config` in `modules/lib/ingest/tuta_session.py` and re-stage.

A session from an older bridge usually still decrypts; when it does not, the
`session-rejected` alert asks for the one-time login again.

## Freshness

Mail is an ingest source with a 12 h window (`modules/lib/ingest-vm.nix`):
`ingest-heartbeat.timer` reads `state/tuta.last-ok` and pages at most once per
window when no batch arrives. A quiet mailbox is not staleness — the collector
emits a batch for every new message, and the ICS renderer emits its
`calendar-unavailable` alert only once per boot because it dedupes through
`calendar-state.json`. A bridge session that dies is caught by its own
`session-rejected` / `minimum-client` alert, so the freshness window only has to
catch a feed that stopped for a day.

## Verification

Always available (no Tuta account, no root):

```sh
nix build .#tuta-ics \
          .#checks.x86_64-linux.unit-tests \
          .#checks.x86_64-linux.kanbei-ingest-guards \
          .#checks.x86_64-linux.format \
          .#checks.x86_64-linux.statix \
          .#checks.x86_64-linux.deadnix
nix eval .#nixosConfigurations.smortress --apply 'c: (c.extendModules { modules = [ ({ lib, ... }: { ingestVm.enable = lib.mkForce true; kanbeiVm.enable = lib.mkForce true; }) ]; }).config.microvm.vms.ingest-tuta.config.config.system.build.toplevel.drvPath'
```

Hardware/credential gated (root on smortress, real Tuta account):

1. Build and switch with `ingestVm.enable` on; confirm
   `systemctl status microvm@ingest-tuta` and, inside the guest console,
   `systemctl status tutabridge tutabridge-session ingest-tuta-mail`.
2. `tutabridge health` inside the guest, then send one mail to the account and
   watch a `batch` file appear in `/var/lib/kanbei-ingest/state` and a
   `tuta-<UTC>-<seq>.age` file in `/var/lib/data/inbox`.
3. Send one mail from the account and confirm the alert mail arrives (Sent
   alert), then check `kanbei-logs writer-tuta` for the `alert` event.
4. Confirm SMTP is loopback only: `ss -ltnp` inside the guest shows 1143/1025
   on `127.0.0.1`, and no listener on the tap address.
5. Calendar: the daily `calendar-unavailable` alert is expected until the SDK
   fetcher builds. `tuta-ics --input <export> --out <ics> --print-fingerprint`
   renders an export end to end.
