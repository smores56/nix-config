# Kanbei ingest plane

Five Firecracker microVMs carry the ingest sources into Kanbei's read-only inbox.
Each guest has one tap, one read-only secret block device and one vsock channel;
the host writer age-encrypts every batch to Kanbei's published recipient. No
guest has a route to the LAN or the internet: the only reachable services are the
host's allowlist proxy and resolver on that tap's host address, and the per-tap
forward chain drops everything else.

Sources, allowlists, windows, taps and ports live in one table:
`modules/lib/ingest-vm.nix`. Host and guest rendering is
`modules/nixos/ingest-vm.nix`. Behind `ingestVm.enable`, which also requires
`kanbeiVm.enable` because the writer needs Kanbei's key.

## Guests

| guest | source | tap | tap /30 | guest MAC | vcpu / mem | vsock cid / port | secret contract | allowlist | window |
|---|---|---|---|---|---|---|---|---|---|
| `ingest-tuta` | `tuta` | `vm-i-tuta` | `10.77.10.0/30` | `02:00:0a:4d:0a:02` | 1 / 256 MiB | 10 / 7010 | `/run/secrets/tuta-env` | `app.tuta.com` | 1800 s |
| `ingest-finance` | `finance` | `vm-i-finance` | `10.77.11.0/30` | `02:00:0a:4d:0b:02` | 1 / 192 MiB | 11 / 7011 | `/run/secrets/finance-env` | `bridge.simplefin.org` | 129600 s |
| `ingest-brave` | `brave` | `vm-i-brave` | `10.77.12.0/30` | `02:00:0a:4d:0c:02` | 1 / 1024 MiB | 12 / 7012 | `/run/secrets/brave-env` | `sync-v2.brave.com` | 86400 s |
| `ingest-immich` | `immich` | `vm-i-immich` | `10.77.13.0/30` | `02:00:0a:4d:0d:02` | 1 / 128 MiB | 13 / 7013 | `/run/secrets/immich-env` | `immich.sammohr.dev` | 21600 s |
| `search` | `search` | `vm-search` | `10.77.14.0/30` | `02:00:0a:4d:0e:02` | 2 / 2048 MiB | 14 / 7014 | `/run/secrets/search-env` | (none) | 86400 s |

Each guest is Firecracker (`microvm.hypervisor = "firecracker"`), has a mandatory
`microvm.socket` at `/var/lib/microvms/<guest>/firecracker.sock`, exactly one
`type = "tap"` interface, no shares and no PCI devices. The read-only host store
is the Firecracker squashfs store disk, not a share. Heartbeat windows are
defaults in the table; the verifier's `search` guest has no production emitter
yet (see below), so its window is only a backstop.

Tap names are shorter than the guest names because Linux caps interface names at
15 bytes.

## Secret staging

Every source has one `/run/secrets/<source>-env` contract (sops key names:
`ingest-tuta-env`, `ingest-finance-env`, `ingest-brave-env`, `ingest-immich-env`,
`ingest-search-env`). The host unit `ingest-vm-secret-<source>.service`:

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
   `sent_at`, `items`; `v == 1`; `kind == "batch"`; `source` equals the writer's
   configured source; `items` is a list; `seq` a non-negative integer. Anything
   else closes the connection, logs a refusal, and exits `65` (the failure email
   carries the unit journal).
5. Encrypt the frame with `age --encrypt -r <recipient>` and atomically install
   it in `/var/lib/data/inbox` as `<source>-<UTCYYYYMMDDTHHMMSS.ffffffZ>-<seq>.age`
   (mode `0644`, so the guest payload user can read it through the share).
6. Record freshness in `/var/lib/kanbei-ingest/state/<source>.last-ok`
   (`0600` root) and acknowledge with one `{"ack": <seq>}\n` line. The guest
   moves the outbox file to `sent/` only after that acknowledgement.

Guest unit: `ingest-emit.service` in every ingest guest listens on AF_VSOCK port
`<vsock port>`, ships every `*.json` file from `/var/lib/ingest/outbox`, and
moves invalid files to `rejected/` without touching the wire. Collectors write
batch files there and must run with the guest proxy variables (`environment.variables`
covers login shells; a system service sets them explicitly, as `ingest-emit` does). `search` also runs `ingest-test-seed.service`, which writes one
deterministic probe batch (items `[{"probe":"kanbei-ingest-verify"}]`) for the
verifier.

Files the writer never accepts: a frame over 1 MiB, a heartbeat envelope on the
batch port, a batch whose `source` is another VM's, unknown JSON keys, and a
non-integer `seq`.

## Age key publication

Kanbei owns the private key; only the recipient crosses the boundary. The host
unit `ingest-age-key.service` listens on the AF_UNIX path Firecracker exposes for
guest-initiated vsock:

```
/var/lib/microvms/kanbei/notify.vsock_7100
```

Kanbei dials host CID 2 on port 7100 and writes exactly one `age1...` line. The
listener validates the recipient shape (62 characters, bech32 charset), writes it
atomically to `/var/lib/kanbei-ingest/age-recipient` (`0400` root) and replies
`OK\n`; any other line gets `ERR\n` and leaves the previous recipient in place.
Writers block on the file, so starting an ingest guest before Kanbei only delays
the first batch.

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

## Freshness heartbeats

`ingest-heartbeat.timer` runs `ingest-heartbeat.service` every 300 s. The service:

- reads `/var/lib/kanbei-ingest/state/<source>.last-ok` for every source;
- writes one aggregate, age-encrypted envelope to
  `/var/lib/data/inbox/heartbeat-<epoch>.age` with per-source `stale`,
  `window_s`, `last_ok` and `age_s`;
- when a source exceeds its window, starts
  `cloudflare-email@ingest-writer-<source>.service` at most once per window, so a
  dead source raises a host alert without a mail storm;
- prunes heartbeat files older than 168 h; batch files are never pruned.

Defaults are the `windowSeconds` column above: Tuta 30 min, finance 36 h, Brave
24 h, Immich 6 h, search 24 h. The `search` source has `alert = false`: its test emitter is not a
production feed, so staleness is still visible in the envelope but never pages.
Change a window in `modules/lib/ingest-vm.nix` (and its row here); the alert
rate limit follows the same value.

## Logs and viewer

Every ingest unit writes a root-only file log under `/var/log/kanbei-ingest/`
(0700 root) in addition to the journal; guest consoles are the
`microvm@<guest>` journal, which is root-only. The viewer is a script, not a
daemon:

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
          .#checks.x86_64-linux.unit-tests \
          .#checks.x86_64-linux.format \
          .#checks.x86_64-linux.statix \
          .#checks.x86_64-linux.deadnix
nix run nixpkgs#python3 -- tests/test_ingest.py
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
  `iptables -S ingest-search-fwd` ends in DROP with no non-conntrack ACCEPT.

The age identity in the round-trip is a temporary test key written under `/run`;
production batches are encrypted to Kanbei's published recipient and only the
guest can decrypt them.
