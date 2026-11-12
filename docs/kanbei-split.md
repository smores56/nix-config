# Kanbei split: threat model and accepted residuals

The #509 split moves the private data into a NIC-less `kanbei` VM and the
home-infra agent into a `cluster` VM. The host keeps only plumbing and the
human's own tools. This file records what the host boundary does **not** stop,
so a later review can re-open a residual on purpose rather than by accident.
Operator steps live in `docs/manual-steps.md` (`host/smortress`); the design
itself is `smores56/sdlc#509`.

## What is trusted

- Host root reads everything: every guest disk, `/dev/vfio`, swtpm state,
  relay sockets and `kanbei`'s logs. Root on the host is outside the bar.
- `maki` runs unsandboxed as `smores`, who is in `wheel`. A touch of the
  YubiKey is the human authorization for sudo; the ticket lasts 15 minutes on
  that TTY (the owner reverted the zero-ticket default).
- Guests that escape their VM (or a kernel/hypervisor 0-day) reach the host and
  therefore everything. Physical separation is the upgrade path.

## Host hardening that ships

`modules/nixos/host-hardening.nix`, enabled only on `smortress`:

- `Defaults timestamp_timeout=15,tty_tickets,use_pty`: a touch buys a 15-minute
  ticket scoped to that TTY, and the command runs on a fresh pty so a process
  left in the caller's terminal cannot type into it. The owner reverted the
  original zero-ticket default on 2026-11-12; the shorter window was part of the
  design, and the wider ticket is an accepted residual.
- `kernel.yama.ptrace_scope=2`: only a parent or `CAP_SYS_PTRACE` may attach,
  so one process of `smores` cannot read another's memory or environment.
- `/proc` remounted `hidepid=2,gid=proc`: other users' process entries (and
  thus their command lines and environment) are invisible. `smores`' login
  shells see only `smores` and root-owned entries the kernel still allows.
- `td` and `v` invoke `/run/wrappers/bin/sudo` (and the wrapper binaries
  themselves) by absolute path, so a `sudo` planted earlier on `PATH` is never
  the binary that receives the touch.
- maki's prompt (`modules/features/ai/agent-context.nix`) tells it to never run
  anything that needs superuser rights and to ask the human instead.

### The `proc` group

`gid=proc` is the kernel's allow-list: a process in group `proc` sees every
`/proc` entry regardless of `hidepid`. NixOS removed
`security.hideProcessInformation` because its remount does not survive cgroups
v2, so the module owns the remount and adds only the units upstream requires:
`systemd-logind.service` and the `user@.service` template (systemd#12955).
Their children — every systemd *user* service of `smores` — inherit the group
and therefore the wider view; interactive login shells do not.

A monitoring agent that must enumerate all processes has to be added to the
group explicitly, e.g. `systemd.services.<name>.serviceConfig.SupplementaryGroups
= [ "proc" ]`. No monitoring agent runs on `smortress` today, so the only
members are the two systemd units above. The first switch remounts `/proc`
right away, but a `user@` instance already running predates its drop-in; reboot
(or `loginctl terminate-user smores`) once before trusting user services.

Verify on the host after a switch:

```sh
cat /proc/1/cmdline >/dev/null && echo "hidepid not active"
ps -eo user,pid,args            # as smores: no other user's processes
cat /proc/sys/kernel/yama/ptrace_scope   # 2
sudo -v                       # one touch; the next sudo in this TTY should not prompt
```

## The `cluster` guest

`modules/nixos/cluster-vm.nix` (smortress only) runs a qemu microVM named
`cluster`: 8 vcpu, 15 GiB, one tap (`vm-cluster`, `10.77.1.0/30`, host
`10.77.1.1`), and single-node k3s 1.35. The guest has no other NIC. Shared
facts (tap, `/30`, MAC, state paths) come from `modules/lib/vm-host.nix`; the
`agent` guest keeps its own constants.

- Addons Flux owns are disabled: `traefik`, `servicelb`, `metrics-server`.
  CoreDNS and the `local-storage` addon stay: Flux's Git sources need cluster DNS,
  and the platform's `local-path` StorageClass is k3s's built-in provisioner, so
  every PVC depends on it; Flux does not own that addon.
- gVisor is registered through `services.k3s.containerdConfigTemplate`
  (`io.containerd.runsc.v1`) with `pkgs.gvisor` on the k3s unit's `PATH`. The
  template extends k3s's own `base` (the legacy v2 template the NixOS module
  writes; containerd 2 still renders it). The `gvisor` RuntimeClass
  (`handler: runsc`) is a platform-repo object (`smores56/sdlc#578`), not a
  guest object. Kata is the documented fallback runtime and is not configured.
- The kubeconfig is published through a rw share at
  `/var/lib/cluster-vm/kubeconfig/admin.conf` with the tap address, so
  `sudo cluster-kubectl get nodes` works from the host as root.

### PV contract

App data stays on the host; each tree is a rw virtiofs share and becomes a
static PV. The host paths and their restic coverage are unchanged.

| Host path | Guest mount | Static PV (platform repo) |
|---|---|---|
| `/var/lib/data/immich` | `/mnt/data/immich` | `immich-data` |
| `/var/lib/data/music` | `/mnt/data/music` | `music-data` |
| `/var/lib/data/books` | `/mnt/data/books` | `books-data` |
| `/var/lib/data/graphiti` | `/mnt/data/graphiti` | `graphiti-data` |

The one-way **cluster digest** is not in that table: the host tree is
`/var/lib/kanbei-ingest/shares/cluster-digest` (not `/var/lib/data`, whose 0751
`smores:users` owner could rename the child), the tree is 0770
`kanbei-digest:kanbei-digest` (uid/gid 983) inside a `0700 root:root` parent chain,
the CronJob reaches it through its own `--translate-uid`/`--translate-gid` mapping
of guest 0/1000 onto 983, and `smores` can neither read nor write it. The guest
mount is unchanged at `/mnt/data/cluster-digest`, which is what the platform's
`cluster-digest-data` PV references, so the host move is invisible to
`homelabs-platform`. It is a feed into Kanbei, not app data, so it needs no restic
coverage.

The PVs are `hostPath` (the mount is node-local and single-node); T6 declares
them in `homelabs-platform`. Every data share uses an explicit virtiofsd
translation, never the agent VM's squash to `smores`: guest root maps to host
`nobody` (65534), guest uid 1000 keeps its identity, and guest gid 0/1000 map
to host `users` (100). Files an app writes therefore land as `smores:users`,
and guest root cannot plant host-root-owned files. Pods must run as uid 1000
(PSA `restricted` requires non-root anyway); a pod running as root can read the
trees but only writes as `nobody`. `--modcaps=-mknod` keeps guest root from
creating device nodes in the mount. The cluster-digest share is the exception:
both guest 0 and 1000 map to the dedicated `kanbei-digest` uid (983), so nothing
the cluster writes is owned by, or readable by, the human account.

### Firewall and the Kanbei boundary

The design says "nftables"; this host has `networking.nftables.enable = false`
and the agent guest already owns iptables chains, so the cluster uses iptables
too. One mechanism filters every tap: dedicated `cluster-vm-in` and
`cluster-vm-fwd` chains, jumped to from the top of `INPUT`/`FORWARD`, replaced
atomically by `iptables-restore --noflush`, and never unjumped. The forward
policy is default-deny: no `vm-*` to `vm-*` forwarding at all (the `vm-+`
wildcard covers future taps, including a Kanbei relay tap), private networks
are dropped, and the only new-connection flows are TCP 80/443, DNS (53) and
NTP (123). The host input chain accepts replies only; nothing on the host is
reachable from the guest. The cluster has no route to and no rule for a Kanbei
relay, and evaluation asserts that no generated rule names a Kanbei tap.

### Manual steps

1. **k3s token.** The guest reads `/run/secrets/k3s-cluster-token`. The sops
   contract is a `k3s-cluster-token` key in `secrets/smortress.yaml`, declared
   in `modules/hosts/smortress/secrets.nix`; the host prep unit copies
   `/run/secrets/k3s-cluster-token` into the guest's read-only share when it
   exists. The key is not in the yaml yet (it cannot be encrypted from this
   checkout), so add it with `sops secrets/smortress.yaml` and declare it. Until
   then the prep unit generates a host-local token at
   `/var/lib/cluster-vm/secrets/k3s-cluster-token` (0400, `nobody`), which
   survives reboots. `manual-steps-sync` has no `secret/k3s-cluster-token`
   anchor until the key exists in a `secrets/*.yaml` file; adding the anchor
   early would fail the check as stale.
2. **Firewall.** No manual step: the chains are applied by
   `networking.firewall.extraCommands`. Verify with
   `sudo iptables -S cluster-vm-in` and `sudo iptables -S cluster-vm-fwd`.
3. **Host access.** `sudo cluster-kubectl get nodes` uses
   `/var/lib/cluster-vm/kubeconfig/admin.conf`. To run a gVisor pod, apply a
   pod with `runtimeClassName: gvisor` once the platform repo declares the
   RuntimeClass.
4. **Boot.** Ring 0 only: no nested-KVM or VFIO need. The guest needs the tap,
   15 GiB RAM and a 64 GiB `var.img` on the host.

## The `kanbei` guest

`modules/nixos/kanbei-vm.nix` (smortress only, gated by `kanbeiVm.enable`,
default off) runs the private-data guest and owns the host side: operator steps
in `docs/manual-steps.md`, design and recovery flow in
[`docs/kanbei-vm.md`](kanbei-vm.md).

- Both functions of the 3090 (`0000:08:00.0` `10de:2204`, `0000:08:00.1`
  `10de:1aef`) are bound to `vfio-pci` and passed through. They sit alone in
  IOMMU group 16, so no ACS override is needed; `kanbei-vm-verify` re-checks the
  binding, the group contents and that no `nvidia` module is loaded.
- The guest has no NIC. `vault` (ro) and `todo` (rw) are virtiofs shares with
  the cluster guest's uid translation, so guest root maps to host `nobody` and
  the guest payload uid 1000 maps to the host `vault` user (981). On the host,
  `todo` is a size-capped ext4 image (`/var/lib/todo.img`, 256 MiB) mounted at
  `/var/lib/data/todo`; the virtiofsd unit is ordered after that mount, so the
  guest sees the mounted tree, never the plain directory an unmounted image
  would leave behind.
- `/var/lib/microvms/kanbei/data.img` is a LUKS2 container. Restic snapshots
  only that ciphertext, after a hook that stops the guest (a dirty image is not
  snapshotted) and restarts it. The swtpm state, the console log, the recovery
  escrow and `inbox` are never in a snapshot (asserted for the swtpm).
- The seal binds to the per-VM swtpm's state and no PCR policy: the guest boots
  with `-kernel` and no firmware, so a kernel rebuild never strands the unlock.
  Losing `/var/lib/kanbei-vm/swtpm` does — the recovery key then opens the image
  from the host with `cryptsetup`.
- The guest console goes to a root-only file, the swtpm state and the console
  directory are 0700 root, and `kanbei` units deliberately carry no
  `cloudflare-email@` failure hook.
- The inference lanes (T11) are one GPU `llama-server` (unified q8_0 KV pool,
  160k tokens, four slots) and two CPU servers (embeddings, reranking), all bound
  to `127.0.0.1`. Weights are data on the LUKS volume with a sha256 manifest,
  never in the store. The pool math, eval protocol and the
  `q8_0`/`--kv-unified-per-slot` residuals are in
  [`docs/kanbei-inference.md`](kanbei-inference.md).
- The access path (T12) is a private hostname route, not a public service:
  `kanbei.sammohr.dev` reaches the guest only through WARP, cloudflared's
  Layer-4 hostname route, a loopback TCP→vsock relay under its own
  `kanbei-relay` uid, and TLS terminated **in the guest**. The relay parses
  nothing; prompt text crosses the host as ciphertext. The guest UI is a static
  human-owned bundle under a strict CSP, Kanbei returns JSON only, model output
  is rendered as text nodes and never auto-linked, and the passkey is a
  server-challenged stub. Details, the exact OpenTofu fragment and the spikes
  are in [`docs/kanbei-access.md`](kanbei-access.md).

## The ingest plane (T14)

`modules/nixos/ingest-vm.nix` (smortress only, gated by `ingestVm.enable`, which
requires `kanbeiVm.enable`) runs five Firecracker guests — `ingest-tuta`,
`ingest-finance`, `ingest-brave`, `ingest-immich` and `search` — and the host
writer, proxy, resolver and heartbeat. Table, protocol, allowlists and defaults
are in [`docs/kanbei-ingest.md`](kanbei-ingest.md).

- Firecracker has no shares and no PCI passthrough: each guest reads its store
  from the read-only store disk, gets its credentials from one read-only ext4
  block device staged from `/run/secrets/<source>-env`, and talks to the host
  only over one vsock channel.
- The writer validates the batch schema and source, caps frames at 1 MiB,
  age-encrypts with `age -r` to Kanbei's published recipient, and drops the
  ciphertext (0600 root, inbox 0750 root) into `/var/lib/data/inbox` (the
  read-only `inbox` share into the Kanbei guest). Kanbei dials host CID 2 port
  `7100`; the host listener requires peer CID 4 and a first-line token, and
  writers block until the recipient file exists.
- Egress is a hostname/SNI proxy and an allowlist resolver on each tap's host
  address. The generated per-tap iptables chains admit only those two services
  and end the forward chain in DROP; no ingest tap is NATed. The guest repeats
  the restriction on its own OUTPUT chain.
- A 5-minute timer writes an age-encrypted heartbeat envelope into the inbox and
  raises `cloudflare-email@ingest-writer-<source>` once per window when a source
  is stale. Logs are root-only files plus the journal; `kanbei-logs` is a
  sudo-run viewer, not a daemon.
- `kanbei-ingest-verify` (root only) proves a batch round-trips, a
  non-allowlisted DNS name and SNI are refused, and the guest cannot egress
  directly. `kanbei-ingest-guards` fails evaluation on a hostname outside a
  source's permit table or on an extra egress rule.

### ingest-tuta (T15)

`ingest-tuta` is the only guest holding a send-capable Tuta session. TutaBridge
runs on loopback (IMAP 1143, SMTP 1025, SMTP never exposed) over a session
staged from the one read-only secret device, with `app.tuta.com` as the only
allowed egress. A stdlib IMAP collector (`BODY.PEEK`, UID plus UIDVALIDITY
dedupe, size caps, IDLE with a UID SEARCH fallback) emits new mail and any new
Sent item; the Sent item is also an `alert` batch, which the host writer turns
into the same failure mail a broken unit raises. The collector watches the
bridge's own log and pages on a Tuta minimum-client rejection or a rejected
saved session, once per day per reason. Calendar changes come from
`pkgs/tuta-ics`: a strict, unit-tested RFC 5545 renderer with a feature-gated,
read-only SDK fetcher. The session bootstrap, bump procedure and limits are in
[`docs/kanbei-ingest-tuta.md`](kanbei-ingest-tuta.md).

### ingest-finance (T16)

`ingest-finance` holds one read-only SimpleFIN Access URL (a bearer credential
stored only on the read-only secret device) and polls `/accounts` daily; both
Schwab and Chase come through the Bridge's MX connections, with their known
reliability caveats surfaced as alert batches rather than silent gaps. The
collector parses protocol v2 (`connections[]`, `errlist`) and falls back to v1
(`errors[]`, `org`), keeps an epoch cursor with a three-day overlap, dedupes on
account+posted+amount+description, and renders deterministic hledger journals
(`assets:bank:<connection>:<account>` plus a balancing income/expense posting)
with balances every run. Plaid is a disabled-by-default fallback behind
`ingestVm.financePlaid.enable`: `/link/token/create` is human-gated, the
`/transactions/sync` cursor is persisted per Item, and
`production.plaid.com` is the only host the option adds. Details and the
one-time claim are in [`docs/kanbei-ingest-finance.md`](kanbei-ingest-finance.md).

### ingest-brave (T17)

`ingest-brave` is a Brave profile joined to the owner's Sync chain. The profile
seed (`Preferences` `brave_sync.v2.seed`) is planted from the read-only secret
device and every Brave run uses `--password-store=basic`, so the fixed OSCrypt
key opens it; the one headful join runs under Xvfb with a real window and is a
manual unit, with the seed-export path as the supported alternative. A daily
`--headless=new` pull is followed by a History-only collector that snapshots the
SQLite database, cursors on `(visit_time, visit_id)`, strips fragments and
userinfo, drops non-web schemes, and dedupes on URL+timestamp. Egress is
`sync-v2.brave.com` only. The chain carries no passwords (Bitwarden), and the
accepted residual is in [`docs/kanbei-ingest-brave.md`](kanbei-ingest-brave.md):
a compromised VM or a stolen seed can copy every synced type to an attacker
chain on Brave's servers (decision 49).

### ingest-immich (T18)

`ingest-immich` reads only Immich metadata: asset fields, EXIF, places, people
and album membership. The client's endpoint allowlist is
`/api/search/metadata`, `/api/albums` and `/api/people`; every `/original`,
`/thumbnail`, `/download`, `/video` and generic `/api/assets` path is refused
before dialling, responses must be JSON and are size-capped. Pagination follows
`nextPage`/`nextCursor`, the cursor is `(updatedAt, id)`, and album/people joins
are fetched only when their `updatedAt` moves. The only egress is the host proxy
and resolver for `immich.sammohr.dev`: no cluster address is reachable, and the
platform side stays unchanged. The scoped key, endpoint and manual steps are in
[`docs/kanbei-ingest-immich.md`](kanbei-ingest-immich.md).

### Cluster digest (T21)

The platform CronJob writes `latest.json` into the `cluster-digest` share
(`/mnt/data/cluster-digest` in the guest, backed by the host's root-parented
`/var/lib/kanbei-ingest/shares/cluster-digest`) every 15 minutes. The host ingest
writer watches it with a stat-before/stat-after stable read, dedupes on
`generated_at`, age-encrypts each new document into the inbox, and records the
document epoch for the T14 heartbeat, which now carries host sources alongside
guests. A stale digest pages exactly like a stale guest, using the shared marker
so the writer and the heartbeat never double-page.

## The phone pipeline (T19)

The phone is the one ingest source without a VM. SMS Import/Export and a
source-built, INTERNET-less fork of `healthconnect-export` write their daily
exports into one Syncthing folder (`sms/`, `health/`, `contacts/`), which the
phone shares to the host `vault` Syncthing as **receive encrypted**. The host
stores only ciphertext at `/var/lib/data/phone-untrusted` (0700 `vault`); the
folder password lives in `secrets/smortress.yaml`, reaches the guest through the
read-only `kanbei-secrets` share, and is staged 0400 inside the LUKS volume.

The guest's `syncthing-decrypt.timer` runs hourly: it refuses a missing password
(exit 10) or a non-receive-encrypted folder (exit 11), decrypts to a temp tree,
merges additively with content-hash dedupe and a 16 MiB per-file cap, then
atomically exchanges the staging tree with `/var/lib/kanbei/phone`. Each run
writes `manifest.json` plus a heartbeat, and newly consumed files produce a
`source=phone` batch envelope in `phone-state/batches/` for the inbox reader
(#600). Host restic backs up the ciphertext tree and the LUKS image, never the
plaintext tree.

Device setup, password custody, the exact SMS Import/Export settings, the fork
patch and its manifest/permission gate, schedules and verification are in
[`docs/kanbei-phone.md`](kanbei-phone.md). Accepted residual: blocked numbers
(needs the default SMS/phone app) and MMS binary payloads are not in the daily
export; the size cap rejects them if the toggles are re-enabled.

## Accepted residuals

### A later human touch runs whatever the unattended maki planted

Decision 47. sudo's touch is not bound to a command: `pam_rssh` authorizes
"this process may become root now", not "this argv may run". An unattended maki
session (as `smores`) can therefore:

- shadow `sudo` with a wrapper in an rc file (`~/.zshrc`, `~/.config/fish`), a
  `PATH` directory (`~/.local/bin`), or a shell function/alias, or
- drop a payload in a place the owner's next session executes (a shell startup
  file, a systemd user unit, a zsh/fish completion script),

and the payload runs with host root on the owner's next touch, because the
owner's `sudo` resolves the plant first. Absolute `/run/wrappers/bin/sudo` in
`td` and `v` closes that path only for those two commands; a human typing
`sudo ...` by hand still resolves through their own shell's config. From host
root, everything in the threat model is reachable, including `kanbei`.

Why accepted: the alternative is a separate UID or command-bound authorization
for maki (a `sudo` rule per command, or a privileged helper that only accepts
an allow-list). The owner chose the touch residual over running maki as its own
user, and the restated goal is "unattended maki cannot reach Kanbei **without a
later human touch**". The 15-minute per-TTY ticket widens this window: once the
owner authenticates, any process on that TTY can use the ticket until it
expires. Revisit if maki ever gets a separate UID or sudo gains a command-bound
approval flow.

### Proc-group members keep a wider process view

`systemd-logind.service` and `user@.service` are in group `proc` (see above).
Their children — `smores`' user services — can read every process entry,
including root's. This is what keeps user managers and D-Bus session services
working; removing it needs a systemd version that no longer reads other users'
`/proc` entries. A monitoring agent added to the group deliberately widens it
further.

### The public wildcard still resolves `kanbei.sammohr.dev`

`*.sammohr.dev` is a proxied CNAME, so the name has a public DNS answer even
though it is a private hostname route. Nothing serves it publicly: cloudflared
has no ingress rule for the name (the tunnel's `http_status:404` catch-all
answers), and the Access application denies the request before cloudflared. The
host module asserts `webProxy.services.kanbei` stays unset and
`modules/nixos/kanbei-access.nix` creates no DNS record; the OpenTofu fragment
creates only the hostname route and the Access app. Replacing the wildcard with
per-host records is the upgrade path if the public answer itself is a concern.

### The Tuta calendar fetcher is not built

`pkgs/tuta-ics` ships and tests the parser/renderer, but its SDK fetcher needs
TutaBridge's prepared `tutanota` checkout (a pinned submodule plus the patch
series that adds the AEAD reads calendar bodies need) and bindgen, none of which
this repository or the Nix sandbox has. The guest's ICS timer therefore emits a
daily `calendar-unavailable` alert and renders a manually exported event JSON,
instead of claiming an empty calendar. Mail is unaffected: it arrives through
IMAP, not the SDK. Revisit when the prepared SDK is vendored or published; the
switch is a fetcher binary plus an `events.json`, with no unit change.

### Kanbei's passkey verifier is a stub

The guest stores WebAuthn challenges server-side, single-use, purpose-bound and
expiring; the browser flow and RP/origin binding are real. Attestation and
assertion signature verification is not implemented yet, so the passkey does
not yet authenticate a session. Access over WARP is the current gate.

### Same-UID capture while `td` or a `v` session is open

`v <cmd>` runs the tool itself as `vault` (no mount, no uid mapping) and `td`
runs tuxedo as `vault`. Any other process of `smores` can read the terminal
(pty, scrollback) while either is open; `hidepid` does not hide terminals of the
same UID. The window is the process's lifetime by design.

### Exfiltration channels that remain

- The `search` VM's capped queries leak a few dozen bits each to TinyFish;
  DLP, the length cap and the Guardian judge bound the rate, not the fact.
- `nanobot` (Neuralwatt) sees cluster metadata and allowlisted log fields;
  Graphiti's extraction inputs go to Neuralwatt under a no-training policy.
- Prompt-injected model output reaches the owner's browser only through the
  CSP-locked, JSON-only UI shell; a browser or terminal escape from another
  window is out of scope. The shell has no remote resource, no auto-linking and
  no markdown HTML path, so a `![](https://…)` or `[label](https://…)` in model
  output is inert text (proven by `tests/kanbei_browser.py`).
- Kanbei prompt text now crosses the host boundary as TLS ciphertext. The relay
  and cloudflared handle only bytes; the guest holds the only key. Host root can
  read the guest's memory and disk and is outside the bar, and Cloudflare sees
  the request routing (SNI/hostname) but not the payload while Gateway TLS
  inspection stays off.

## Data apps on the `cluster` guest (T6)

Immich, Navidrome, Calibre and Graphiti move from host services into the guest,
one namespace and one virtiofs share each. The platform manifests are in
`smores56/homelabs-platform` (`clusters/homelab/data/`, `platform/storage/`,
`platform/network/`, `ingress/`); this repository keeps the share, the storage
paths and the cutover switch.

- **Shares are the existing trees.** The guest mounts `/var/lib/data/{immich,music,books,graphiti}`
  at `/mnt/data/<share>` with the uid translation described above, so the pods
  write the same inodes the host's restic job walks. Each namespace is
  pre-bound to one share by a static PV (`local.path: /mnt/data/<share>`,
  `claimRef`, node affinity `kubernetes.io/hostname: cluster`). The node name is
  the guest hostname, not discovered at runtime; confirm with
  `cluster-kubectl get nodes -o wide`.
- **Two new admission policies** (`data-pvc-scope`, `data-pvc-storage`) keep a
  data pod on its own namespace's claim, which is what stops Immich from
  mounting the music or books library after a compromise.
- **Dumps before restic.** The platform CronJobs run at 02:45 Europe/Berlin and
  are capped at 30 minutes, so `immich.dump` and `graphiti.rdb` are complete
  before this host's restic units start at 03:30 (+ up to 15 minutes of random
  delay). They write inside the shares, so restic needs no hook. That replaces
  `systemd.services.restic-db-dump` here; disabling it is part of the switch
  below.
- **Tunnel split.** The host's tunnel (`web-proxy.nix`, tunnel `smortress`) keeps
  `ssh`, `llm`, `chat`, `agent` and `memory` and is untouched. The cluster's
  `cloudflared` is a second, separate tunnel in the `ingress` namespace of the
  guest, with its own token from a SOPS contract; the Cloudflare objects (tunnel,
  DNS, Access) are T7.

### The cutover switch

`modules/nixos/cluster-data-apps.nix` holds `clusterDataApps.enable`, default
`false`. While it is off the module is inert, so it can be wired before the
cluster serves anything. Turning it on:

- forces `services.immich.enable` and `services.navidrome.enable` off;
- empties `virtualisation.oci-containers.containers` (the `memory` stack);
- disables `memory-{falkordb,graphiti-mcp,llm-proxy,mcp,export}.service` and the
  `memory-export` timer;
- disables `restic-db-dump.service`, whose dump the platform CronJob replaces;
- asserts the above and that the `cluster` guest exists.

It does **not** delete the native modules, the `memory` user and group, the
`/var/lib/data/memory-export` tmpfiles entry, calibre's home-manager unit
(`modules/features/calibre.nix`, another plane) or the trigger for the memory
route. Those are the live-gated remainder of `smores56/sdlc#580`: delete
`modules/nixos/{immich,navidrome,memory}.nix` (and their server-profile entries,
the `memory` user/group and the host podman stack) only after every app has
served from the cluster and the memory wrapper has moved. `disabledModules`
cannot carry that for us: it is read while the module list is collected, before
any option has a value.

Exact wiring, in `modules/hosts/smortress/default.nix`:

```nix
nixosModules = [ ... ./cluster-data-apps.nix ];   # once, inert at the default
nixosOptions.clusterDataApps.enable = true;       # the cutover
```

The second line alone is the switch; the first is what makes the option exist
on that host.

## Retirement table (T9)

`kanbeiSplit.cutover.enable` (`modules/kanbei-split.nix`, assertions in
`modules/nixos/kanbei-cutover.nix`) is the single switch. It defaults to
`false`, so the host keeps serving nanobot, Letta and Open WebUI exactly as it
does today; a switch on the default generation is byte-identical in behavior.
Flipping it removes the units below but **keeps every module file** until the
follow-up deletion commit. The option is shared by both planes so the laptop
chat proxies read the same value as the server.

| Component | Owned by | At `cutover = true` | Deleted in the follow-up commit | Operator/credential step |
|---|---|---|---|---|
| `agent` microVM | `modules/nixos/agent-vm.nix`, `modules/lib/agent-vm*.{nix,sh,py}`, `modules/features/agent-vm/` | no `microvm.vms.agent`, no `microvm@agent`, tap/broker/ingress units or timers | whole files plus the `maki` profile's `nixos` entry and `agentVm.*` host options | none |
| nanobot in the guest | `agent-assistant`, `nanobotConfig`, `pkgs/nanobot` | gone with the guest; the cluster pod is the only runtime | `pkgs/nanobot/` and its overlay entry, the guest `nanobot-assistant` unit and state paths | the cluster app owns its config (`homelabs-apps`) |
| Letta App Server | `agentLetta`, `letta-assistant`, `pkgs/letta`, MemFS state | gone with the guest | `pkgs/letta/` and its overlay entry, `agentLetta`, the state and restic paths, the `letta-package` check | delete the retired MemFS tree after the last export |
| Open WebUI | `modules/nixos/open-webui.nix` | unit gone; `/var/lib/data/open-webui` is no longer served | file, `server` profile entry, `webProxy.services.agent`, `ports.openWebui` | delete the `agent` Access app and its hostname route in the follow-up (`tofu`) |
| files-mcp | `modules/nixos/filesearch.nix` | unit gone | file, `server` profile entry, `filesearch` host options, `ports.filesMcp` | none; it was never registered as a client tool |
| laptop chat proxy | `modules/features/chat-proxy.nix` | no user unit/launchd agent on smorespro or smoreswork | file and the two `homeModules` entries | keep `cloudflare-access-ssh-token`: cloudflared still uses it |
| GitHub mirror | was `modules/nixos/github-backup.nix` | removed now; the platform CronJob runs it | `modules/features/backup/` helpers and their checks after the platform copies land | delete the yaml key and revoke the classic PAT (manual, encrypted file) |
| secret-sweep review | `secret-sweep --review` | removed now; gitleaks only | none further | none |
| nanobot local fallback | `nanobotConfigAttrs` | removed now; no `smortress` provider or `local` preset | none further | none |
| `a` alias | `modules/features/ai/maki/default.nix`, `modules/features/agent-vm/default.nix` | removed now: `maki` on personal hosts, `claude` on smoreswork | none further | none |
| `jupyter-token` | encrypted `secrets/smortress.yaml` only | declaration already gone | no code; delete the yaml key by hand | `sops secrets/smortress.yaml` |
| Radicale htpasswd | already deleted in `906a1b5e` | nothing to do | none | none |

### Follow-up deletion list

Run only after a live `cutover = true` generation has served every consumer and
the cluster owns the assistant. Files and directories:

```
modules/nixos/agent-vm.nix
modules/lib/agent-vm.nix
modules/lib/agent-vm-linux.sh
modules/lib/agent-vm-update.sh
modules/lib/agent-vm-verify.sh
modules/lib/agent_view.py
modules/lib/share_planner.py
modules/lib/agent-broker/
modules/features/agent-vm/
modules/nixos/open-webui.nix
modules/nixos/filesearch.nix
modules/features/chat-proxy.nix
pkgs/letta/
pkgs/nanobot/
```

Also in that commit: drop the `nanobot`/`letta` overlay entries
(`pkgs/overlays.nix`), the `maki` profile's `../nixos/agent-vm.nix` entry, the
`server` profile's open-webui/filesearch entries, `agentVm.*` and
`filesearch.*` host options, the `cloudflare-access-ssh-token` reads in
`modules/nixos/ssh.nix`, the `assistantState`/`lettaState` branch in
`modules/nixos/restic-backup.nix`, `ports.{agent,letta,openWebui,filesMcp}`,
the `webProxy.services.{agent,nanobot}` entries, the `agent-vm-*` and
`letta-package` checks, and `tests/{agent-vm,test_agent_broker,test_agent_view,test_share_planner}*`.
The `modules/features/backup/` helpers leave once the platform repo carries
them; until then they remain tested but unrun. Keep
`modules/nixos/kanbei-cutover.nix` until these deletions land, then fold its
assertions into the host module or delete it with the option.
