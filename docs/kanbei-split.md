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
  YubiKey is the human authorization for sudo, and one touch grants root for
  that command.
- Guests that escape their VM (or a kernel/hypervisor 0-day) reach the host and
  therefore everything. Physical separation is the upgrade path.

## Host hardening that ships

`modules/nixos/host-hardening.nix`, enabled only on `smortress`:

- `Defaults timestamp_timeout=0,use_pty`: every sudo spends its own touch, and
  the command runs on a fresh pty so a process left in the caller's terminal
  cannot type into it. Without this a single touch bought 15 minutes
  (`modules/nixos/ssh.nix`).
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
sudo -v; sudo -v                # each prompts for a fresh touch
```

## The `cluster` guest

`modules/nixos/cluster-vm.nix` (smortress only) runs a qemu microVM named
`cluster`: 8 vcpu, 15 GiB, one tap (`vm-cluster`, `10.77.1.0/30`, host
`10.77.1.1`), and single-node k3s 1.35. The guest has no other NIC. Shared
facts (tap, `/30`, MAC, state paths) come from `modules/lib/vm-host.nix`; the
`agent` guest keeps its own constants.

- Addons Flux owns are disabled: `traefik`, `servicelb`, `local-storage`,
  `metrics-server`. CoreDNS stays: Flux's Git sources need cluster DNS and no
  platform manifest declares it yet.
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

The PVs are `hostPath` (the mount is node-local and single-node); T6 declares
them in `homelabs-platform`. Every data share uses an explicit virtiofsd
translation, never the agent VM's squash to `smores`: guest root maps to host
`nobody` (65534), guest uid 1000 keeps its identity, and guest gid 0/1000 map
to host `users` (100). Files an app writes therefore land as `smores:users`,
and guest root cannot plant host-root-owned files. Pods must run as uid 1000
(PSA `restricted` requires non-root anyway); a pod running as root can read the
trees but only writes as `nobody`. `--modcaps=-mknod` keeps guest root from
creating device nodes in the mount.

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
later human touch**". Revisit if maki ever gets a separate UID or sudo gains a
command-bound approval flow.

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
