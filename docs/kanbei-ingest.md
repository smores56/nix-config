# Kanbei ingest plane

Five Firecracker microVMs carry the ingest sources into Kanbei's read-only inbox.
Each guest has one tap, one read-only secret block device and one vsock channel;
the host writer age-encrypts every batch to Kanbei's published recipient. No
guest has a route to the LAN or the internet: the only reachable services are the
host's allowlist proxy and resolver on that tap's host address, and the per-tap
forward chain drops everything else. The `search` guest also serves Kanbei's
capped query API on a second vsock listener; see
[`docs/kanbei-search.md`](kanbei-search.md).

Sources, allowlists, windows, taps and ports live in one table:
`modules/lib/ingest-vm.nix`. Host and guest rendering is
`modules/nixos/ingest-vm.nix`. Behind `ingestVm.enable`, which also requires
`kanbeiVm.enable` because the writer needs Kanbei's key.

## Guests

| guest | source | tap | tap /30 | guest MAC | vcpu / mem | vsock cid / port | secret contract | allowlist | window |
|---|---|---|---|---|---|---|---|---|---|
| `ingest-tuta` | `tuta` | `vm-i-tuta` | `10.77.10.0/30` | `02:00:0a:4d:0a:02` | 1 / 256 MiB | 10 / 7010 | `/run/secrets/ingest-tuta-env` | `app.tuta.com` | 43200 s |
| `ingest-finance` | `finance` | `vm-i-finance` | `10.77.11.0/30` | `02:00:0a:4d:0b:02` | 1 / 256 MiB | 11 / 7011 | `/run/secrets/ingest-finance-env` | `bridge.simplefin.org` (+ `production.plaid.com` when enabled) | 129600 s |
| `ingest-brave` | `brave` | `vm-i-brave` | `10.77.12.0/30` | `02:00:0a:4d:0c:02` | 1 / 1024 MiB | 12 / 7012 | `/run/secrets/ingest-brave-env` | `sync-v2.brave.com` | 86400 s |
| `ingest-immich` | `immich` | `vm-i-immich` | `10.77.13.0/30` | `02:00:0a:4d:0d:02` | 1 / 256 MiB | 13 / 7013 | `/run/secrets/ingest-immich-env` | `photos.sammohr.dev` | 64800 s |
| `search` | `search` | `vm-search` | `10.77.14.0/30` | `02:00:0a:4d:0e:02` | 2 / 2560 MiB | 14 / 7014 (query 7024) | `/run/secrets/ingest-search-env` | `api.search.tinyfish.ai` | 86400 s |

Each guest is Firecracker (`microvm.hypervisor = "firecracker"`), has a mandatory
`microvm.socket` at `/var/lib/microvms/<guest>/firecracker.sock`, exactly one
`type = "tap"` interface, no shares and no PCI devices. The read-only host store
is the Firecracker squashfs store disk, not a share. Heartbeat windows are
defaults in the table; the verifier's `search` guest has no production emitter
yet (see below), so its window is only a backstop.

The `search` guest is the one exception to the single-volume rule: it mounts the
secret image at `/run/ingest-secret` and the Guardian model image at
`/run/search-model`, both read-only, plus a small writable image at
`/var/lib/search` for the persisted limiter (the guest root is tmpfs). Its batch
port 7014 still feeds the verifier; the query API listens on 7024 because one
vsock port cannot carry two protocols.

Tap names are shorter than the guest names because Linux caps interface names at
15 bytes.

## Secret staging

Every source has one `/run/secrets/ingest-<source>-env` contract, named for its
sops key (`ingest-tuta-env`, `ingest-finance-env`, `ingest-brave-env`,
`ingest-immich-env`, `ingest-search-env`). The host unit
`ingest-vm-secret-<source>.service`:

1. copies the contract file to a private staging directory at mode `0400`;
2. builds a 4 MiB ext4 image around it (`/env`, mode `0400 root:root`) with
   `mkfs.ext4 -d`;
3. installs the image at `/var/lib/microvms/ingest-secrets/<source>.img`, mode
   `0440 root:kvm` because Firecracker runs as `microvm:kvm` and refuses to open
   a root-only image;
4. records the source digest in `<image>.sha256` so an unchanged secret is not
   re-staged, and refuses to replace the image while `microvm@<guest>` runs.

The guest mounts the image read-only at `/run/ingest-secret` (`/dev/vdb`; the
store disk is `vda`) and reads `/run/ingest-secret/env`. Only the source's own
credentials go in that file. Missing contract files fail the unit and keep that
guest down; the other guests and the host are unaffected. Steps are in
`docs/manual-steps.md`.

`/run/secrets` is a sops-nix generation directory: each activation rebuilds it
and removes every file it does not manage. The five contracts are declared in
`modules/hosts/smortress/secrets.nix` behind `ingestVm.enable`, so sops-nix
writes them from `secrets/smortress.yaml` on every switch and nothing prunes
them; how to mint each value is in `docs/manual-steps.md`. The image under
`/var/lib/microvms/ingest-secrets/` stays the copy the guest reads: if a key is
removed later the unit keeps the existing image and exits 0
(`… is absent; keeping the staged image`), and a contract whose digest changed
replaces the image, which still requires the guest to be stopped.

`ingest-search-env` carries exactly one line, `TINYFISH_API_KEY=<key>`: Kanbei's
own key, never the host's or nanobot's. The search guest adds two images:
`/var/lib/microvms/search-model/guardian.img` (`0440 root:kvm`), built by
`search-vm-model.service` from the operator-fetched, hash-checked Guardian GGUF
(`modules/lib/search-models.json`) and mounted read-only at `/run/search-model`
(`/dev/vdc`); and `/var/lib/microvms/search-state/state.img` (`0660 root:kvm`),
created once by `search-vm-state.service` and mounted read-write at
`/var/lib/search` (`/dev/vdd`) so the rate/budget counters survive a restart.
Without the model or secret image the guest does not start.

## Writer protocol

Host unit: `ingest-writer-<source>.service` (one per source, `Restart=always`,
`OnFailure=cloudflare-email@%n.service`).

1. Block until `/var/lib/kanbei-ingest/age-recipient` exists and validates; a
   malformed file exits non-zero instead of waiting.
2. Connect to the guest's Firecracker UDS
   `/var/lib/microvms/<guest>/notify.vsock`, send `CONNECT <vsock port>\n` and
   require `OK <assigned host port>\n`.
3. Read frames: a 4-byte big-endian length followed by that many UTF-8 bytes of
   JSON. The cap is 1 MiB per frame; zero-length and larger frames are refused.
4. Validate the batch schema: exactly the keys `v`, `source`, `kind`, `seq`,
   `sent_at`, `items`; `v == 1`; `kind` is `batch` or `alert`; `source` equals
   the writer's configured source; `items` is a list; `seq` a non-negative
   integer. Anything else closes the connection, logs a refusal, and exits `65`
   (the failure email carries the unit journal). An `alert` batch is encrypted
   like any other, and the writer additionally starts
   `cloudflare-email@ingest-writer-<source>.service`: the guest has no mail path
   of its own, so the host turns the alert into the same page a failed unit
   raises (a new Sent item, a Tuta client rejection).
5. Encrypt the frame with `age --encrypt -r <recipient>` and atomically install
   it in `/var/lib/data/inbox` as `<source>-<UTCYYYYMMDDTHHMMSS.ffffffZ>-<seq>.age`
   (mode `0600` root; the inbox directory is `0750` root, so only guest root reads the
   batches through the read-only share — no world-readable copy exists).
6. Record freshness in `/var/lib/kanbei-ingest/state/<source>.last-ok`
   (`0600` root) and acknowledge with one `{"ack": <seq>}\n` line. The guest
   moves the outbox file to `sent/` only after that acknowledgement.

Guest units per source: `ingest-emit.service` in every ingest guest listens on AF_VSOCK port
`<vsock port>`, ships every `*.json` file from `/var/lib/ingest/outbox`, and
moves invalid files to `rejected/` without touching the wire. Collectors write
batch files there and must run with the guest proxy variables (`environment.variables`
covers login shells; a system service sets them explicitly, as `ingest-emit` does). `search` also runs `ingest-test-seed.service`, which writes one
deterministic probe batch (items `[{"probe":"kanbei-ingest-verify"}]`) for the
verifier.

Files the writer never accepts: a frame over 1 MiB, a heartbeat envelope on the
batch port, a batch whose `source` is another VM's, unknown JSON keys, a
non-integer `seq`, and an unknown `kind`.

The `ingest-tuta` guest adds its own units on top of `ingest-emit`:
`tutabridge-session.service`, `tutabridge.service` (loopback IMAP/SMTP),
`ingest-tuta-mail.service` and `ingest-tuta-ics.timer`; see
[`docs/kanbei-ingest-tuta.md`](kanbei-ingest-tuta.md).

The three data sources each add one collector timer and keep their own state:

| guest | units | state | docs |
|---|---|---|---|
| `ingest-finance` | `ingest-finance.service`, `ingest-finance.timer` (daily) | `/var/lib/finance/state.json` | [`docs/kanbei-ingest-finance.md`](kanbei-ingest-finance.md) |
| `ingest-brave` | `ingest-brave-sync.service` (seed + headless pull), `ingest-brave-history.service`, `ingest-brave-history.timer` (daily), manual `brave-sync-join.service` | `/var/lib/brave/{state.json,profile}` | [`docs/kanbei-ingest-brave.md`](kanbei-ingest-brave.md) |
| `ingest-immich` | `ingest-immich.service`, `ingest-immich.timer` (6 h) | `/var/lib/immich/state.json` | [`docs/kanbei-ingest-immich.md`](kanbei-ingest-immich.md) |

Every collector caps memory (`MemoryHigh`/`MemoryMax`), writes only to its own
state directory and `/var/lib/ingest/outbox`, and keeps dedupe state across
restarts. Finance is the only source whose allowlist has an optional second
host: `production.plaid.com` enters the policy only with
`ingestVm.financePlaid.enable`.

## Search guest

The `search` guest is the only egress for Kanbei's capped queries (#594). Its
query API is one JSON line in and one JSON line out on vsock cid 14, port 7024.
Kanbei dials **host CID 2, port 7101**; `search-relay.service` binds that host
AF_VSOCK port itself (there is no Firecracker UDS: the caller is the qemu kanbei
guest). The connection must come from peer CID 4 and its first line must be
`KANBEI-AUTH 1 <token>` — the token comes from a root-only systemd credential
(`/var/lib/kanbei-vm/secrets/relay-token`, the same file the Kanbei guest reads from
its read-only secret share) and is compared in constant time. Only then does the
relay dial the search guest's `notify.vsock` (`CONNECT 7024`) and pipe bytes. A
wrong CID, a wrong token, or a dead guest closes Kanbei's connection rather than
returning an empty result. The relay logs connection metadata and byte counts to
`/var/log/kanbei-ingest/search-relay.log`; it never parses or logs payload.

Inside the guest, `searchd` runs the fixed ladder: DLP scan, ~100-character cap,
persisted per-minute rate and daily budget, then the Granite Guardian judge,
whose CPU `llama-server` listens on loopback. Any failure blocks. Only the
admitted query leaves through the host proxy to `api.search.tinyfish.ai`; results
return as stripped, bounded plain text. The guest holds exactly one credential,
the `TINYFISH_API_KEY` line in `/run/ingest-secret/env`, and the Guardian weights
as a read-only block device. Gate details, the wire schema, thresholds and the
planted suite are in [`docs/kanbei-search.md`](kanbei-search.md).

## Age key publication

Kanbei owns the private key; only the recipient crosses the boundary. The host
unit `ingest-age-key.service` binds **host AF_VSOCK port 7100** directly (the kanbei
guest is qemu, so there is no Firecracker `notify.vsock_7100` to forward through).

Kanbei dials host CID 2 on port 7100 and sends:

```
KANBEI-AUTH 1 <token>\n
age1...\n
```

The listener requires peer CID 4, compares the token in constant time against the
root-only credential, then validates the recipient shape (62 characters, bech32
charset), writes it atomically to `/var/lib/kanbei-ingest/age-recipient` (`0400`
root) and replies `OK\n`; any other line (or a missing/wrong token) gets `ERR\n`
and leaves the previous recipient in place. Writers block on the file, so starting
an ingest guest before Kanbei only delays the first batch.

## Egress control

All guest traffic goes to the tap's host address:

| service | listener | admits |
|---|---|---|
| `ingest-proxy` | `10.77.<idx>.1:3128` | CONNECT and absolute-form HTTP for that source's allowlist only |
| `ingest-resolver` | `10.77.<idx>.1:53` (UDP) | A/AAAA for that source's allowlist only; REFUSED otherwise |

Proxy rules:

- the peer must be that tap's guest address (`10.77.<idx>.2`) and the listener
  must be that source's gateway; anything else is refused before parsing;
- CONNECT is HTTPS-only (port 443); IP literals, userinfo, non-numeric ports and
  names outside the allowlist are refused;
- the TLS SNI in the first ClientHello must equal the CONNECT host, and the SNI
  is checked **before** any upstream connection exists, so a mismatched hello
  never leaves the host;
- absolute-form requests must name the same host in the request target and the
  `Host` header; proxy-authorization headers are dropped;
- logs are metadata only (time, source, host, port, decision, byte counts);
  paths, queries and payload bytes never appear.

Resolver rules: exactly one question, plain DNS, A/AAAA only, qname in the
listener source's allowlist; every other query gets REFUSED. Answers that are
private, loopback, link-local or reserved are dropped, so a compromised
allowlisted name cannot point a guest at the LAN. The chosen implementation is the
stdlib responder in `modules/lib/ingest/resolver.py`: one listener per tap keyed
by the source is simpler than per-interface dnsmasq instances and reads the same
policy file. UDP is the only DNS transport the taps admit.

Firewall: the host generates two iptables chains per source,
`ingest-<source>-in` and `ingest-<source>-fwd`, restored from
`/etc/kanbei-ingest/rules.v4` and jumped to only for that tap. The input chain
admits conntrack plus the proxy and resolver on the tap's host address, then
drops. The forward chain admits only conntrack and ends in DROP; there is no
ACCEPT for port 80/443, no NAT entry for any ingest tap, and no rule may mention
another source's tap. The guest repeats the policy on its own OUTPUT chain
(proxy and resolver only, then REJECT). Evaluation fails if a generated rule
grants more than that (`ingest.validateFirewall`), and
`checks.x86_64-linux.kanbei-ingest-guards` mutates the table and rules to prove
both a non-allowlisted hostname and an extra egress rule are rejected.

## Cluster digest (host-written source)

The `cluster` guest's platform CronJob rewrites
`/mnt/data/cluster-digest/latest.json` every 15 minutes
(`homelabs-platform`, `platform/digest/`). `modules/nixos/cluster-vm.nix` shares
the host tree `/var/lib/kanbei-ingest/shares/cluster-digest` into the guest, and
`ingest-writer-cluster-digest.service` reads it from the host side:

- `read_stable` stats before and after the read and retries when inode, size or
  mtime moved, so a rename or a virtiofs update is never read half-written;
- the document must be `schema_version` `1` with `generated_at`, `cluster` and
  `nanobot_activity`; anything else exits `65` and pages (the platform contract
  changed, which is not something to truncate here);
- `generated_at` is the cursor (`state/cluster-digest.cursor`), so a restart or a
  replayed `latest.json` never re-emits; an older document is logged as a replay;
- each new document is age-encrypted to Kanbei's recipient and installed as
  `cluster-digest-<UTC>.age` (the source id is already in the file name);
- the writer records `state/cluster-digest.last-ok` with the document's epoch so
  the heartbeat sees digest freshness, and pages once per window when the newest
  `generated_at` is older than `hostSources.cluster-digest.windowSeconds` (3600 s)
  using the shared `<source>.alerted` marker.

The digest tree is **not** a human-owned data share. It is
`/var/lib/kanbei-ingest/shares/cluster-digest`, mode `0770`, owned by the dedicated
`kanbei-digest` uid (983) — never `smores`. It deliberately does **not** live under
`/var/lib/data`: that directory is `0751 smores:users`, so its owner could rename or
replace any child tree whatever the child's own mode. The parent chain
(`/var/lib/kanbei-ingest`, `/var/lib/kanbei-ingest/shares`) is `0700 root:root`, so
the share itself is the only writable object and the human cannot even traverse to
it. The cluster guest reaches it through an explicit
`--translate-uid`/`--translate-gid` mapping for guest 0 and 1000 onto that uid, so
the CronJob's writes land as `kanbei-digest`, a compromised workload cannot write as
the human, and the host writer (root) is the only reader. `smores` can neither read
nor write the directory, its contents or its parents; `kanbei-ingest-verify` proves
it with `runuser -u smores -- test -r/-w` on the tree and both private parents (and
`test -w` on `/var/lib` and `/var`). The share assertion in `cluster-vm.nix`, the
writer assertion in `ingest-vm.nix` and `kanbei-ingest-guards` fail evaluation if the
tree moves back under `/var/lib/data`, either side is renamed, or the mapping drops
back to a human uid. The guest path stays `/mnt/data/cluster-digest`, so the platform
PV contract (`cluster-digest-data`) is unchanged.

## Freshness heartbeats

`ingest-heartbeat.timer` runs `ingest-heartbeat.service` every 300 s. The service:

- reads `/var/lib/kanbei-ingest/state/<source>.last-ok` for every guest source
  and every `hostSources` entry (today `cluster-digest`);
- writes one aggregate, age-encrypted envelope to
  `/var/lib/data/inbox/heartbeat-<epoch>.age` (`0600` root, like every inbox file)
  with per-source `stale`, `host`, `window_s`, `last_ok` and `age_s`, plus the
  `host_sources` list;
- when a source exceeds its window, starts
  `cloudflare-email@ingest-writer-<source>.service` at most once per window, so a
  dead source raises a host alert without a mail storm;
- prunes heartbeat files older than 168 h; batch files are never pruned.

Defaults are the `windowSeconds` column above: Tuta 12 h, finance 36 h, Brave
24 h, Immich 18 h, search 24 h, and the host-written cluster digest 60 min. The
`search` source has `alert = false`: its test emitter is not a production feed,
so staleness is still visible in the envelope but never pages. The digest
writer pages on its own timer and shares the heartbeat's marker file, so the two
never double-page.
Change a window in `modules/lib/ingest-vm.nix` (and its row here); the alert
rate limit follows the same value.

## Logs and viewer

Every ingest unit writes a root-only file log under `/var/log/kanbei-ingest/`
(0700 root) in addition to the journal; guest consoles are the
`microvm@<guest>` journal, which is root-only. The search guest adds
`search-relay.log` and its own `search.log`/`judge.log` inside the guest, whose
`searchd` output reaches the `microvm@search` journal. The viewer is a script, not
a daemon:

```
/run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs
/run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs writer-tuta
```

It refuses to run without root or outside sudo (the absolute wrapper), then tails
the file logs and the ingest/Kanbei journal units. Nothing is world-readable and
no log socket is exposed.

## Verification

The eval checks and unit tests run anywhere:

```sh
nix build .#checks.x86_64-linux.kanbei-ingest-guards \
          .#checks.x86_64-linux.kanbei-search-suite \
          .#checks.x86_64-linux.unit-tests \
          .#checks.x86_64-linux.manual-steps-sync \
          .#checks.x86_64-linux.eval-nixos-smortress \
          .#checks.x86_64-linux.format \
          .#checks.x86_64-linux.statix \
          .#checks.x86_64-linux.deadnix
nix run nixpkgs#python3 -- -m unittest tests.test_ingest tests.test_ingest_tuta tests.test_ingest_finance tests.test_ingest_brave tests.test_ingest_immich tests.test_search_gates tests.test_search_service tests.test_search_suite
nix run nixpkgs#python3 -- tests/search/run_suite.py
```

The hardware-gated proof runs only as root on smortress (it stops the production
search writer, reboots the `search` guest, and restores the writer):

```
/run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-ingest-verify
```

It asserts:

- **round-trip**: the guest's seeded batch goes through `ingest-writer`, is
  age-encrypted, decrypts with the test identity, carries the probe item, and
  creates `<source>.last-ok`;
- **secret**: the guest reports `/run/ingest-secret/env` at mode `0400`;
- **DNS**: `example.com` and another source's `app.tuta.com` are REFUSED;
- **SNI**: a CONNECT for a non-allowlisted host is refused, and a ClientHello
  whose SNI differs from an allowlisted CONNECT host is refused before dialling;
- **egress**: the guest's own probe logs `INGEST-EGRESS-DROPPED`, and
  `iptables -S ingest-search-fwd` ends in DROP with no non-conntrack ACCEPT;
- **digest**: the tree is `0770 kanbei-digest` inside a `0700 root` parent chain,
  and `runuser -u smores` can neither read nor write the tree or its private
  parents (nor write `/var/lib`/`/var`); the workspace check asserts the share,
  the writer's state files and the heartbeat's host-source entry, and the writer
  itself is proven by `tests/test_ingest_tuta.py` (stable read, cursor dedupe,
  staleness alert, host path outside `/var/lib/data`).

The age identity in the round-trip is a temporary test key written under `/run`;
production batches are encrypted to Kanbei's published recipient and only the
guest can decrypt them.
