# ingest-brave: headless Brave on the Sync chain

The `ingest-brave` guest runs one Brave profile joined to the owner's Sync
chain, pulls the chain headlessly once a day, and emits History visits as
browsing batches. It never holds a password: passwords live in Bitwarden, so the
chain carries none of them.

Module: `modules/nixos/ingest-vm.nix` (guest block `lib.mkIf (id == "brave")`).
Table entry: `modules/lib/ingest-vm.nix`. Tools:
`modules/lib/ingest/brave_sync.py` (profile seed) and
`modules/lib/ingest/brave_history.py` (History collector). Tests:
`tests/test_ingest_brave.py`. Package: `pkgs.brave` (nixpkgs, MPL-2.0).

## Why a chain member at all

Brave Sync is server-mediated: another device's history is only visible to a
client that is a member of the same chain. There is no headless CLI to join, and
the chain is end-to-end encrypted with a key that only the chain members hold.
The guest therefore has to be a real Brave profile with a real seed, not an HTTP
client. The supported unattended path is a planted seed; the one headful session
below is the fallback.

## Profile and seed

Brave's OSCrypt encrypts the sync seed held at `Preferences`
`brave_sync_v2.seed` — a flat key, not `brave_sync.v2.seed` — and stores it as
**base64 of the raw blob** (`v10` + IV + ciphertext), so a `v10<base64>` string
lifted straight out of the file is not what Brave reads. On Linux the default
keyring may be unavailable under Xvfb, so every Brave invocation in this guest
passes `--password-store=basic`: the fixed "peanuts" key then decrypts the seed,
and a seed from another basic-store profile is portable. The contract carries
the blob as the `v10<base64>` text and `brave_sync.py` converts it when planting.
The guest never logs the seed; it reports only `seed_present` and whether the
value looks like OSCrypt.

`ingest-brave-sync.service`'s seed step runs before each pull and:

1. reads `/run/ingest-secret/env` (only `BRAVE_SYNC_SEED` and, for the join
   fallback, `BRAVE_SYNC_CODE` are accepted keys);
2. writes the seed at the dotted key and sets `sync.requested`,
   `sync.keep_everything_synced` and `sync.has_setup_completed` — the three the
   join UI normally writes. Without them Chromium's SyncService never starts;
   with only the first two the profile registers on the chain (gaia_id,
   transport state) but never runs the initial download. Every other
   `Preferences` value and the file mode `0600` are preserved;
3. stages the 25-word code at `/run/brave/sync-code` (`0600`) when present.

Without a seed the profile stays unseeded and the pull logs that; the manual
join below is the only remaining path.

### One-time join (human)

**Preferred: export the seed from a joined profile.** On a workstation whose
Brave profile is already in the chain, with Brave closed:

```sh
prefs="$HOME/.config/BraveSoftware/Brave-Browser/Default/Preferences"
# stored: base64(b"v10" + IV + ciphertext); contract: "v10" + base64(IV + ciphertext)
jq -r '.brave_sync_v2.seed' "$prefs" | base64 -d | tail -c +4 | base64 -w0
```

Prefix that output with `v10` and put it in the secret contract as
`BRAVE_SYNC_SEED=v10<output>`, then re-stage `ingest-brave-env`. The blob is portable because both profiles use
`--password-store=basic`; a keyring-encrypted seed is not.

**Fallback: Xvfb paste.** Put the 25-word code in the secret as
`BRAVE_SYNC_CODE=word1 word2 …` (it rotates daily) and start the manual unit;
it runs Xvfb `:99` with a real 1280×800 window, opens
`brave://settings/braveSync/setup`, and types the staged code after 12 s:

```sh
# inside the guest console
systemctl start brave-sync-join
journalctl -u brave-sync-join -f
```

The guest exposes no display transport, so this path is only usable with an
X11 client added for the session; it is documented as the spike result, not the
routine path. After either path, `brave_sync.py --status` reports
`seed_present: true`; then clear `BRAVE_SYNC_CODE` from the contract.

### Chain passphrase backup

A 25-word code is a one-day recovery code and rotates; it is not a backup. Set
a **custom sync passphrase** in Brave's Sync settings and store it in Bitwarden
(the vault, not the chain). The passphrase is what decrypts the chain's synced
types if every device is lost; without it the server-side ciphertext is
unreadable. Never store the passphrase in `ingest-brave-env`: the guest needs
only the seed.

## Sync pull and History collector

| unit | purpose |
|---|---|
| `ingest-brave-sync.service` | seed step, then `brave --headless=new` for a bounded 180 s pull |
| `ingest-brave-history.service` | snapshot History, emit new visits |
| `ingest-brave-history.timer` | daily at 04:37 with up to 60 min jitter, `Persistent=true` |
| `brave-sync-join.service` | the manual Xvfb join above; no `wantedBy` |

The timer triggers the History collector, which `Wants=` the sync service:
`After=ingest-brave-sync.service` means the pull completes (or times out) before
History is read. Both are `oneshot`; `MemoryHigh/Max` is 640/800 MiB for Brave
and 96/128 MiB for the collector, and the guest is 1 GiB. `--no-sandbox` is
required because the guest runs Brave as root in a single-purpose VM;
`--disable-dev-shm-usage` avoids Chromium's small `/dev/shm`.

The collector:

- takes a consistent snapshot with SQLite's backup API, falling back to copying
  `History`, `History-wal` and `History-shm` into a private workdir when Brave
  holds the database open;
- reads `visits JOIN urls` with a `(visit_time, visit_id)` cursor, so a restart
  at the same microsecond does not replay;
- converts Chromium's microseconds-since-1601 to UTC ISO stamps;
- emits only `http`/`https` URLs, strips fragments and userinfo, caps URL at
  2 000 and title at 500 bytes, and skips non-web schemes (`chrome://`,
  `file://`, extensions);
- baselines the first run to a 24 h lookback instead of dumping the whole
  History, then advances the cursor over every scanned row (including skipped
  schemes) so a quiet browser is not re-scanned;
- dedupes on `sha256(url, visit_time)` with the last 20 000 keys kept, and
  chunks at 400 items / 350 KiB per batch.

Items are `{"type":"browse","url","title","visited_at","visit_id"}`. Logs carry
counts (including the whole-database `db_visits` and `db_urls`, so a
zero-emission run is diagnosable — Chromium's HISTORY sync fills `urls`
without creating `visits`), ids and a UTC timestamp only; titles and URLs appear only inside the
encrypted batch. Only History is read: no passwords, bookmarks or open tabs are
collected by this revision.

## Egress

The guest's only allowed name is `sync-v2.brave.com` (host proxy
`10.77.12.1:3128`, SNI-checked; resolver allowlist exact). Chromium takes the
proxy from `--proxy-server`, not the environment. Brave's other services
(component updates, variations, safe browsing, account UI) are refused by the
resolver and the per-tap forward chain ends in DROP; the profile is expected to
show those failures and the sync pull still works.

## Accepted residual

Decision 49: the Sync chain is a shared trust domain. A compromised VM — or
anyone who obtains the seed — can copy every synced type to an attacker's chain
on Brave's servers. Nothing here prevents that; the mitigations are that the
guest is single-purpose, its egress is one host, it carries no passwords
(Bitwarden) and no bookmarks, and a chain compromise is visible only as an
unexpected device. If the chain ever carried a password manager export or
bookmarks, this residual would grow; do not add those types to the chain.

## Freshness and limits

The table's 24 h window matches the daily pull: one missed run is silent, two
page the owner. The pull itself is bounded at 180 s; a hung Brave is killed and
the collector still reads the last local History. A History database larger than
`SEEN_KEEP` keys is fine: dedupe keys are a cache, and the cursor is the
authority.

## Verification

```sh
nix build .#checks.x86_64-linux.unit-tests .#checks.x86_64-linux.kanbei-ingest-guards
nix eval .#nixosConfigurations.smortress --apply 'c: (c.extendModules { modules = [ ({ lib, ... }: { ingestVm.enable = lib.mkForce true; kanbeiVm.enable = lib.mkForce true; }) ]; }).config.microvm.vms.ingest-brave.config.config.system.build.toplevel.drvPath'
```

Hardware/credential gated (root on smortress, a real Brave chain):

1. Export or join the seed, stage `ingest-brave-env`, start
   `microvm@ingest-brave`, and run `ingest-brave-sync --status` in the guest:
   `seed_present: true`.
2. `systemctl start ingest-brave-sync ingest-brave-history`; confirm the pull
   was killed by the 180 s bound (exit 124/137 is normal) and that the collector
   logged `done` with a non-zero `scanned` after browsing on another chain
   device.
3. Confirm `brave-*.age` appears in `/var/lib/data/inbox` and Kanbei shows the
   new visits; `sudo cat /var/lib/kanbei-ingest/state/brave.last-ok`.
4. Prove the egress scope: a CONNECT to `sync.brave.com` from the guest is
   refused, and the guest cannot reach `1.1.1.1` directly.
5. Back up the custom chain passphrase in Bitwarden before treating the chain as
   recoverable.
