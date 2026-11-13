# Manual steps

Everything here is an operator action: work the repo cannot do from Nix.
`checks.manual-steps-sync` derives the inventory from the configuration, so
`nix flake check` fails when an item below is missing an anchor, when an anchor
no longer exists in the config, or when this file still contains an unresolved
placeholder marker.

An anchor is an HTML comment on its own line:

```html
<!-- manual-step: <kind>/<id> -->
```

Kinds: `host`, `secret`, `provider`, `service`, `app`, `alert`.
Adding a host directory, sops key, Tofu provider or notification, public
service, flake app, or alert path means adding its anchor with real
instructions.

## Hosts

The host list comes from `modules/hosts/*/`.

### smortress

<!-- manual-step: host/smortress -->

The always-on server (NixOS, x86_64), and the only host that decrypts
`secrets/smortress.yaml`. Reinstall from a blank disk with:

```sh
nix run .#key-restore -- <bundle>.tar.gz --host-key   # existing identity
nix run .#install -- smortress root@<target-ip>
```

`nix run .#host-key -- smortress` is only for a brand-new host: it mints a new
identity, so `.sops.yaml` and the rules for that host must be re-encrypted with
`sops updatekeys` first. On an existing host it replaces the key its secrets are
encrypted to, and `install` then refuses to proceed.

`install` wipes the target's disks, applies `modules/hosts/smortress/disko.nix`,
generates `hardware.nix`, and delivers the pre-generated host key. Commit the
generated hardware config, then run `nix run .#bootstrap`.

- **Backup disk**: a 4.5T HDD, LUKS2, mounted at `/var/backup` from
  `/dev/mapper/backup` (see [Encrypted backup disk](#encrypted-backup-disk) for
  the format and keyfile procedure). The module only mounts it, with `nofail`;
  the local restic unit declares `RequiresMountsFor` and fails (and alerts)
  when it is absent.
- **Host key**: `/etc/ssh/ssh_host_ed25519_key` is the age recipient that
  decrypts the host's sops file. Losing it means restoring the key or re-keying
  (see [Recovery](#recovery)).
- **Out-of-band access**: the physical console. There is no inbound SSH port;
  SSH is tunnel-only.
- **Agent VM**: `a` runs maki directly on the host (T9). The legacy microvm
  sandbox is still present until `kanbeiSplit.cutover.enable` flips, but it is
  no longer the default path. See [Agent VMs](#agent-vms).
- **Maki signing**: commits inside the agent VM sign with the sops key for the
  repo owner's account (`user.signingkey`, `gpg.format=ssh`) and
  `commit.gpgsign = true`. That is config, not enforcement: `--no-gpg-sign`
  still produces an unsigned commit, which review or PR checks catch.

#### Encrypted root and Secure Boot

The 980 PRO is the final LUKS2 root. `/dev/disk/by-partlabel/root` is the
header, `/dev/mapper/root` is ext4. The **passphrase slot stays** and is the
console break-glass path. Clevis adds an `sss` slot that needs **both** shares,
Tang and TPM2 on PCR 7:

```sh
sudo clevis luks bind -d /dev/disk/by-partlabel/root sss \
  '{"t":2,"pins":{"tang":[{"url":"http://10.0.0.193:7654"}],"tpm2":{"pcr_bank":"sha256","pcr_ids":"7"}}}'
```

The bind is interactive: it asks for the existing LUKS passphrase and to trust
the Tang advertisement. Compare the advertisement against `tang-show-keys` and
answer yes, or pass `-y` once it matches.

Bind only while the final 980 is booted with Secure Boot enforced: PCR 7
measures the Secure Boot policy, so a firmware update, a cleared fTPM, or a
changed `db` invalidates the TPM share. Never bind without `pcr_ids`; never
bind PCR 0/2/4. The passphrase still boots when the policy fails.

Export the token's JWE for the initrd and commit it — it is ciphertext, and the
LUKS header already contains the same token. It is not a secret; the Tang
private key and the TPM are.

Find the token id with `sudo clevis luks list -d /dev/disk/by-partlabel/root`
(usually `0`).

```sh
sudo cryptsetup token export --token-id <id> /dev/disk/by-partlabel/root > /tmp/token.json
jq -r '.jwe | [.protected, (.encrypted_key // ""), .iv, .ciphertext, .tag] | join(".")' \
  /tmp/token.json | tr -d '\n' > modules/hosts/smortress/root.jwe
sudo clevis decrypt < modules/hosts/smortress/root.jwe >/dev/null   # must exit 0
```

The token stores the JWE as a JSON object; `clevis decrypt` reads only the
compact serialization (`protected.encrypted_key.iv.ciphertext.tag`), so
`jq -r .jwe` produces a file the initrd cannot decrypt.

`boot.initrd.clevis` decrypts it to `/clevis-root/decrypted` before
`systemd-cryptsetup@root`; the initrd reaches Tang through the wired NIC
(matched by MAC, static `10.0.0.125/24`) and falls back to the passphrase
prompt when the Tang or TPM share cannot be satisfied. The initrd waits at
most 10 s for that link and 30 s for the Clevis unit, so a dead cable or a
wedged Tang reaches the prompt instead of hanging.

Stage 2 must then take the link back from the initrd. `flushBeforeStage2`
clears the initrd address, and `networkmanager-reclaim-wired` is the
load-bearing guard: when NetworkManager reports the device as "connected
(externally)", it disconnects, flushes, and reconnects the declarative
`smortress-wired` DHCP profile. If a boot comes up with `10.0.0.125` and no
default route, inspect `journalctl -u networkmanager-reclaim-wired -b`; the
tunnel is unreachable without it.

Secure Boot: enable AMD fTPM, set the UEFI supervisor password, and enter Setup
Mode by deleting **PK only** (never "Clear all keys" — that drops `dbx`). Then
`sudo sbctl create-keys`, `sudo nixos-rebuild boot`, `sudo chattr -i
/sys/firmware/efi/efivars/*` when enrollment reports immutable variables,
`sudo sbctl enroll-keys --microsoft`, reboot, and enforce. On ASUS boards set
`OS Type = Windows UEFI Mode`; `Other OS` can leave enforcement off.

**Never `sudo sbctl sign` anything under `/boot/EFI/nixos/`.** The lzbt stub
embeds each kernel/initrd's SHA-256 (the base32 suffix of the filename);
signing rewrites the file and the next boot fails with "Kernel hash does not
match! Did you run lzbt?". Only the stubs are signed, and lzbt signs them.
`/boot` is `0700`, so globs must expand as root:

```sh
sudo sh -c 'sbctl verify /boot/EFI/Linux/nixos-generation-*.efi'   # all ✓
sudo nix-shell -p openssl --run 'for file in /boot/EFI/nixos/*.efi; do
  hash=$(openssl dgst -sha256 -binary "$file" | base32 | tr -d = | LC_ALL=C tr [:upper:] [:lower:])
  [[ $file == *$hash.efi ]] || echo "CORRUPT: $file"; done'
```

If a kernel or initrd is corrupt, delete it and run `nixos-rebuild boot`. If no
generation boots, mount root and ESP from an installer (use
`/dev/disk/by-partlabel/root` / `EFI`, not `/dev/nvmeXn1` — enumeration
changes), delete the corrupt files, and run `nixos-rebuild boot` inside
`nixos-enter`.

After a `db`/firmware change, replace the Clevis slot and re-export the JWE:
`sudo clevis luks unbind -d /dev/disk/by-partlabel/root -s <slot>`, re-run the
bind above, and regenerate `root.jwe`. Then **rebuild** (`sudo nixos-rebuild
boot`): lzbt embeds the JWE in the signed UKI, so without it the next boot
still uses the old token. An older generation keeps its older JWE too, so
rolling back after a re-bind prompts for the passphrase until it is rebuilt.

#### Assistant-host hardening

`hostHardening.enable` (`modules/nixos/host-hardening.nix`) turns smortress
into a host an unattended assistant cannot quietly escalate on. After the first
switch that enables it, confirm all three on the machine:

```sh
sudo -v                          # one touch; the next sudo in this TTY should not prompt
cat /proc/1/cmdline              # as smores: Permission denied
cat /proc/sys/kernel/yama/ptrace_scope   # 2 (or: sysctl kernel.yama.ptrace_scope)
systemctl status proc-hidepid    # active (exited); /proc has hidepid=2,gid=proc
```

The `proc` group is the kernel's allow-list and is held only by
`systemd-logind.service` and `user@.service`; add a monitoring unit to it with
`SupplementaryGroups = [ "proc" ]` when one starts running here. The first
switch remounts `/proc` immediately, but the user manager already running was
started without the group — reboot once (or `loginctl terminate-user smores`)
before trusting user services. What the hardening cannot stop — most
importantly a planted `sudo` that runs on the owner's next touch — is recorded
in [`docs/kanbei-split.md`](kanbei-split.md).

#### Kanbei private-data VM

`kanbeiVm.enable` (default off) boots the NIC-less `kanbei` guest with the RTX
3090 passed through by VFIO, a LUKS2 data volume, and a per-VM swtpm. Design
and state map: [`docs/kanbei-vm.md`](kanbei-vm.md). The four steps below are
one-time or emergency operator actions; none of them is exercised by a build.

**1. Cutover.** Do this with the machine reachable and a console session open
(the switch stops Immich and `llama-cpp`, so the GPU is free but the guest may
need a second boot):

```sh
# Drain the GPU: stop the triage window and the interactive model first.
sudo systemctl stop llama-cpp.service || true
# Flip the gate, then switch. This is the only edit the cutover needs.
#   modules/hosts/smortress/default.nix -> kanbeiVm.enable = true;
just verify-nixos smortress
sudo nixos-rebuild switch
```

A reboot is required for the kernel to claim both functions with
`vfio-pci.ids=10de:2204,10de:1aef`; until then the previous boot's `nvidia`
still owns them and the guest's `pci-setup` fails. Reboot, then:

```sh
sudo systemctl status microvm@kanbei.service kanbei-swtpm.service
sudo kanbei-vm-verify            # vfio-pci bound, group 16 clean, state 0700
```

**2. GPU unbind / rollback.** To go back to host Immich (or when
the guest must not run), undo in this order: set `kanbeiVm.enable = false`,
`sudo systemctl stop microvm@kanbei.service kanbei-swtpm.service`,
`sudo nixos-rebuild switch`, and reboot once so `nvidia` can claim the GPU
again (`vfio-pci` keeps it otherwise). Nothing on disk is destroyed: the LUKS
image and the swtpm state stay under `/var/lib/kanbei-vm` and
`/var/lib/microvms/kanbei`. Never unbind by hand while QEMU is running.

**3. Recovery key.** The first boot generates 64 random bytes and escrows them
at `/var/lib/kanbei-vm/enroll/recovery.key` (0600 root) *before* formatting, so
the volume is never formatted under a key nobody kept. The guest does not print
it (the console path is volatile); harvest it once, in base64:

```sh
sudo base64 -w0 /var/lib/kanbei-vm/enroll/recovery.key; echo
```

Store that **base64** string in the password manager — the file itself is raw
bytes, so the encoding is part of what has to be remembered. Then delete the
escrow (`sudo rm /var/lib/kanbei-vm/enroll/recovery.key`); after that no copy
exists on the machine and losing both the swtpm state and this string loses the
volume. A stable key instead of the generated one: add a `kanbei-recovery-key`
entry to `secrets/smortress.yaml` with `sops secrets/smortress.yaml`, declare it
in `modules/hosts/smortress/secrets.nix`, and add the
`secret/kanbei-recovery-key` anchor to this file (the check requires one per yaml
key). The host prep unit copies it to the guest as a read-only contract; without
the yaml key no anchor exists and the check passes.

**4. Backup restore.** `restic-backups-kanbei-{r2,local}` stop the guest, snapshot
only the ciphertext image, then restart it. To restore: stop the guest, restore
`/var/lib/microvms/kanbei/data.img` (0600 `microvm:kvm`), then check the volume
from the host with the stored recovery key — no TPM needed. Paste the base64
string on stdin so it stays out of the shell history:

```sh
sudo systemctl stop microvm@kanbei.service
sudo sh -c 'umask 077; base64 -d > /run/kanbei-recovery.key'
# paste the stored base64 string, then Ctrl-D
sudo cryptsetup open --key-file /run/kanbei-recovery.key \
  /var/lib/microvms/kanbei/data.img kanbei-data
sudo mount /dev/mapper/kanbei-data /mnt && ls /mnt
sudo umount /mnt && sudo cryptsetup close kanbei-data
sudo rm -f /run/kanbei-recovery.key
```

Start the guest next. If `/var/lib/kanbei-vm/swtpm` was lost, the TPM unlock
fails and the volume stays locked until you re-enroll in an interactive guest
console (`docs/kanbei-vm.md` has the runner command and the
`systemd-cryptenroll --wipe-slot=tpm2 ...` step). These units carry no
`cloudflare-email@` alert on purpose; watch
`journalctl -u restic-backups-kanbei-r2`.

**5. IOMMU check.** After any kernel, firmware or slot change:

```sh
for d in 0000:08:00.0 0000:08:00.1; do basename "$(readlink -f /sys/bus/pci/devices/$d/driver)"; done
ls /sys/kernel/iommu_groups/16/devices   # exactly those two paths
sudo dmesg | grep -i -e 'IOMMU' -e 'ACS' # no "not viable", no ACS override
lsmod | grep nvidia                      # empty while the guest owns the GPU
```

If the group gained a device, stop the guest and re-record the pair in
`modules/nixos/kanbei-vm.nix` rather than widening the passthrough.

**6. Model download and verification.** The guest has no NIC, so the weights are
fetched on the host into the locked volume. The manifest is the contract
(`modules/lib/kanbei-models.json`, installed in the guest as
`/var/lib/kanbei/models/llama-models.json`); the tool refuses a size or sha256
mismatch and never installs a partial file. The volume is 64 GiB and the three
files are 16.36 GB (15.24 GiB), so check free space first — and unlock with the
stored recovery key, because the escrow was deleted after the first TPM boot:

```sh
sudo systemctl stop microvm@kanbei.service
sudo sh -c 'umask 077; base64 -d > /run/kanbei-recovery.key'
# paste the stored base64 string, then Ctrl-D
sudo cryptsetup open --key-file /run/kanbei-recovery.key \
  /var/lib/microvms/kanbei/data.img kanbei-data
sudo mkdir -p /mnt/kanbei-data
sudo mount /dev/mapper/kanbei-data /mnt/kanbei-data
df -h /mnt/kanbei-data                        # >= 17 GiB free

# Fetch, hash-check, install as root:kanbei (guest uid/gid 1000) 0640.
sudo nix shell nixpkgs#python3 -c python3 modules/lib/kanbei-fetch-models.py \
  --dest /mnt/kanbei-data/models --uid 1000 --gid 1000

# Re-verify without the network (this is the check to repeat after any copy).
sudo nix shell nixpkgs#python3 -c python3 modules/lib/kanbei-fetch-models.py \
  --check --dest /mnt/kanbei-data/models

sudo umount /mnt/kanbei-data && sudo cryptsetup close kanbei-data
sudo rm -f /run/kanbei-recovery.key
sudo systemctl start microvm@kanbei.service
```

The tool is idempotent and prints `ok <name>: <path> (<bytes> bytes, sha256
verified)` per model; `--check` exits 2 on a mismatch. A workstation copy is
moved in the same way (mount the image on the host, copy into
`/mnt/kanbei-data/models`, then `--check`). The read-only `inbox` share is **not**
a route for this: the guest's uid 0 appears there as host `nobody`, so the guest
console cannot read a root-owned batch.

Verify the guest picked the files up:

```sh
sudo systemctl status kanbei-chat.service kanbei-embeddings.service kanbei-rerank.service
sudo journalctl -u kanbei-inference-gpu -u kanbei-chat -n 40 --no-pager
# inside the guest console: kanbei-inference-eval
```

`docs/kanbei-inference.md` has the eval thresholds and the f16 reference-server
command for the quality sample.

**7. Publish and gate.** The host publishes the name through the tunnel ingress
(`webProxy.services.kanbei` -> `https://127.0.0.1:443`, in the same generation that
enables `kanbeiVm`). The platform repo's `tofu/kanbei.tf` creates the Access application: a
public destination for `kanbei.sammohr.dev` with the owner email policy and nothing else.
From that repo:

```sh
tests/tofu/check.sh
tofu -chdir=tofu plan   # expect only the kanbei application (plus the route destroy, step 8)
tofu -chdir=tofu apply
```

An unauthenticated request now gets `302` to the Access login; a `404` means the ingress
rule is missing. Nothing is required on the client.

**8. Retire the private route.** If the account still holds the old
`cloudflare_zero_trust_network_hostname_route.kanbei` (or any private route for the name),
delete it: WARP clients would otherwise keep resolving the name to a Gateway
initial-resolved IP instead of the edge. The platform change does this in two applies,
because `prevent_destroy` blocks a destroy until a prior change drops the guard; the exact
sequence is step 21 of that repo's `docs/manual-steps.md`. Verify with
`dig +short kanbei.sammohr.dev` — Cloudflare edge addresses, never `172.64.128.0/20`.

**9. ACME account and token.** The responder runs as `kanbei-acme` and reuses the
`cloudflare-api-token` sops key; DNS-01 needs `Zone:DNS:Edit` on `sammohr.dev` in addition
to the token's existing scopes. Verify or extend the token in the dashboard. Lego creates
its ACME account under `/var/lib/kanbei-acme/lego/accounts` on the first issuance; that
state is disposable (a new account is registered if it is lost). The service is
`kanbei-acme.service`:

```sh
sudo systemctl status kanbei-acme.service
sudo journalctl -u kanbei-acme -n 40 --no-pager
sudo ls -ld /var/lib/kanbei-acme   # 0700 kanbei-acme
```

**10. Certificate issuance.** The guest asks on boot and daily; the host signs only a CSR
for the fixed CN (`kanbei.sammohr.dev`), and only after the peer-CID and relay-token
handshake. Issuance is rate-limited to one certificate per 6 hours via
`/var/lib/kanbei-acme/last-issue` (0600); a forced retry inside the window returns
`issuance rate limited` and invokes no ACME client. To retry sooner, stop
`kanbei-acme.service` and delete that marker deliberately. Watch both sides:

```sh
sudo systemctl status kanbei-cert.service kanbei-cert.timer kanbei-ui.service
sudo journalctl -u kanbei-cert -n 40 --no-pager          # guest console / host journal
sudo ls -l /var/lib/kanbei/tls                           # 0700 root; key/cert 0400 root
sudo ls -l /var/lib/kanbei-acme/last-issue               # 0600, epoch of the last issuance
```

Force a renewal after a CA or token change (in the guest console or via
`sudo systemctl start kanbei-cert.service`), then confirm `kanbei-ui` restarted and serves
the new dates. The private key never leaves the guest: the host ACME state has no key and
Lego is invoked with `--csr`.

The relay token (every Kanbei channel, including the certificate request) is
`/var/lib/kanbei-vm/secrets/relay-token` (0400 root), generated by `kanbei-vm-prep` and
shared read-only into the guest. To rotate it, delete the file and
`sudo systemctl restart kanbei-vm-prep kanbei-chat-relay kanbei-acme ingest-age-key search-relay`
plus `microvm@kanbei.service`; no sops key is involved.

**11. Relay checks.** The host listener is loopback-only and group-restricted:

```sh
ss -lntp 'sport = :443'                     # 127.0.0.1:443, kanbei-chat-relay
sudo iptables -S kanbei-relay-in            # one lo/dport 443 accept, no FORWARD rule
getent hosts kanbei.sammohr.dev             # Cloudflare edge addresses (no hosts entry)
sudo systemctl status kanbei-chat-relay.socket kanbei-chat-relay.service
```

From any device, `https://kanbei.sammohr.dev` shows the Access login; after signing in the
UI loads. Without a session Access denies at the edge and nothing reaches the relay.

**12. Spikes.** Run the three checks in
[`docs/kanbei-access.md`](kanbei-access.md#spikes-and-how-to-run-them): origin certificate
via `openssl s_client`, Access allow with TLS inspection off, and the offline planted-output
Chromium test.

#### Phone pipeline (SMS, calls, contacts, health)

The phone writes its exports into a Syncthing folder shared to this host as **receive
encrypted**, so `/var/lib/data/phone-untrusted` is ciphertext at rest and the password
only exists in the kanbei LUKS volume. Design, device steps and verification:
[`docs/kanbei-phone.md`](kanbei-phone.md). Phone app settings:
[`mobile/sms-ie/SETTINGS.md`](../mobile/sms-ie/SETTINGS.md) and
[`mobile/healthconnect-export/FORK.md`](../mobile/healthconnect-export/FORK.md).

1. **Folder password.** Generate it once (`openssl rand -base64 32`), store it in the
   password manager, add it to `secrets/smortress.yaml` as `phone-folder-password`
   (`sops secrets/smortress.yaml`). The declaration in
   `modules/hosts/smortress/secrets.nix` is gated on `kanbeiVm.enable`, so a host with
   the guest off never asks sops for a key that is not in the yaml (that failed every
   switch before). Add the encrypted key before the first switch with
   `kanbeiVm.enable = true`; the `secret/phone-folder-password` anchor below is kept in
   sync with the committed yaml key.
2. **Phone side.** Set the folder at `/storage/emulated/0/Sync/phone` with folder ID
   `phone`, share it to this host with that password, and grant Syncthing-Fork the
   battery exemption. Install SMS Import/Export and the forked health exporter, then
   apply `mobile/sms-ie/SETTINGS.md` and point the health exporter at the same folder.
3. **First sync.** With the host reachable, the ciphertext lands in
   `/var/lib/data/phone-untrusted` (0700 `vault`). Confirm the share is live:

   ```sh
   sudo -u vault syncthing cli -C /var/lib/syncthing -D /var/lib/syncthing config folders list
   sudo ls -la /var/lib/data/phone-untrusted | head
   # Must fail (exit 1) for the human: 0700 vault is the "not readable at rest" gate.
   sudo -u smores test -r /var/lib/data/phone-untrusted || echo 'not readable as smores'
   ```

   The host prep unit copies `/run/secrets/phone-folder-password` into the guest's
   read-only `/run/kanbei-secrets` share; `systemctl restart microvm@kanbei.service` once
   if the guest booted before the yaml key existed.
4. **Guest decrypt.** The timer runs hourly; the first run prints nothing on success but
   writes the manifest and batch:

   ```sh
   # inside the guest console
   systemctl list-timers 'syncthing-decrypt*'
   systemctl start syncthing-decrypt.service
   journalctl -u syncthing-decrypt -n 40 --no-pager
   ls -l /var/lib/kanbei/phone/{manifest.json,sms,health,contacts}
   ls -l /var/lib/kanbei/phone-state/batches
   ```

   Exit codes are documented in `docs/kanbei-phone.md`; a missing or wrong password
   leaves the existing tree untouched and writes an `alert` batch plus an error
   heartbeat.
5. **Rotation.** Change the folder password on the phone and in
   `secrets/smortress.yaml` in the same window. The sops unit restarts
   `kanbei-phone-password.service`, which re-stages the contract; the guest's next
   decrypt stages it into the LUKS volume. Syncthing on the phone re-encrypts the
   folder when the password changes, so expect a full ciphertext re-sync.

#### Ingest plane (Firecracker)

The five ingest guests and their host writer/proxy/resolver are behind
`ingestVm.enable`, which also requires `kanbeiVm.enable`. The operator surface is
`docs/kanbei-ingest.md`; these are the steps that need a human.

1. **Secret files.** Each source has a `/run/secrets/<source>-env` contract:
   `ingest-tuta-env`, `ingest-finance-env`, `ingest-brave-env`,
   `ingest-immich-env`, `ingest-search-env`. They are sops keys of the same name
   under `/run/secrets`; the encrypted YAML is not in this repo yet, so stage
   them out of band at mode `0400 root:root` before enabling a guest:

   ```sh
   sudo install -m 0400 -o root -g root /path/to/tuta-env /run/secrets/ingest-tuta-env
   sudo stat -c '%a %U:%G %n' /run/secrets/ingest-*-env
   ```

   The secret host unit (`ingest-vm-secret-<source>.service`) copies the file into
   a 4 MiB ext4 image at `/var/lib/microvms/ingest-secrets/<source>.img`; without
   the file that guest stays down and the other sources are unaffected. Changing
   a secret requires stopping the guest first: the unit refuses to replace a live
   image, so `sudo systemctl stop microvm@<guest>` then
   `sudo systemctl start ingest-vm-secret-<source> microvm@<guest>`.

   `ingest-tuta-env` is not a password file: it carries the base64 TutaBridge
   session (`gnupg/`, `pass/`, `config/`) plus the Tuta address and the bridge
   password. Do the one-time login first, then write the file:
   [`docs/kanbei-ingest-tuta.md`](kanbei-ingest-tuta.md#session-bootstrap-one-time-human)
   has the exact commands (`tutabridge init`, tar, base64, `umask 077`). The
   Tuta account password is never stored; only the encrypted session and the
   no-passphrase GPG key that opens it.

2. **Firecracker TAP prerequisites.** Firecracker needs `/dev/kvm`,
   `/dev/net/tun` and `/dev/vhost-vsock`, plus the `tun` and `vhost_vsock` kernel
   modules (the microvm host module loads the first two; `kanbei-vm.nix` loads
   `vhost_vsock`). Confirm:

   ```sh
   ls -l /dev/kvm /dev/net/tun /dev/vhost-vsock
   lsmod | grep -E '^(tun|vhost_vsock)'
   ```

   Tap creation is the root `microvm-tap-interfaces@<guest>.service`; each tap is
   named `vm-i-<source>` (or `vm-search`) so it fits the 15-byte interface limit.
   The host firewall is iptables (`networking.nftables.enable` stays off): the
   per-tap chains are restored from `/etc/kanbei-ingest/rules.v4` and jumped to
   from INPUT/FORWARD by `networking.firewall.extraCommands`. No ingest tap is
   NATed.

3. **First boot.** With the Kanbei VM already enabled, flip `ingestVm.enable`
   in `modules/hosts/smortress/default.nix` (it is pinned off), `nixos-rebuild
   switch`, then:

   ```sh
   sudo systemctl status ingest-vm-prep ingest-proxy ingest-resolver ingest-age-key
   sudo systemctl status microvm@ingest-tuta microvm@ingest-finance microvm@ingest-brave microvm@ingest-immich microvm@search
   sudo systemctl list-timers ingest-heartbeat.timer
   sudo ls -ld /var/lib/kanbei-ingest /var/lib/kanbei-ingest/state /var/log/kanbei-ingest /var/lib/data/inbox
   sudo iptables -S ingest-tuta-in ingest-tuta-fwd
   sudo cat /var/lib/kanbei-ingest/age-recipient        # age1… published by Kanbei
   ```

   The writers block until the recipient exists, so a logged `waiting` event is
   expected until Kanbei has booted and published its key. A missing secret is the
   only reason a guest does not start.

4. **Tuta session and client bumps.** A `minimum-client` alert (or a
   `session-rejected` alert) is the owner's cue. For a bump, update `version`
   and `hash` in `pkgs/tutabridge.nix` from the release's `SHA256SUMS`, rebuild,
   then `sudo systemctl restart microvm@ingest-tuta`. For a rejected session,
   repeat the one-time login and re-stage `ingest-tuta-env`. Both are in
   [`docs/kanbei-ingest-tuta.md`](kanbei-ingest-tuta.md#tuta-client-bumps).

5. **Cluster digest.** `cluster-vm.nix` creates and shares the host tree
   `/var/lib/kanbei-ingest/shares/cluster-digest` (0770
   `kanbei-digest:kanbei-digest`, uid 983) inside a `0700 root:root` parent chain;
   the platform CronJob writes `latest.json` there every 15 minutes through that
   share's uid mapping (the guest path stays `/mnt/data/cluster-digest`, so the
   platform PV is unchanged). Confirm the one-way feed and the ownership gate:

   ```sh
   sudo systemctl status ingest-writer-cluster-digest
   sudo ls -ld /var/lib/kanbei-ingest /var/lib/kanbei-ingest/shares  # 0700 root
   sudo ls -ld /var/lib/kanbei-ingest/shares/cluster-digest          # 0770 kanbei-digest
   sudo -u smores test -r /var/lib/kanbei-ingest/shares/cluster-digest || echo 'not readable as smores'
   sudo -u smores test -w /var/lib/kanbei-ingest || echo 'state root not writable as smores'
   sudo ls -l /var/lib/kanbei-ingest/shares/cluster-digest/latest.json
   sudo cat /var/lib/kanbei-ingest/state/cluster-digest.last-ok
   sudo ls -l /var/lib/data/inbox/cluster-digest-*.age
   ```

   A stale digest pages through `cloudflare-email@ingest-writer-cluster-digest`
   once per hour window. The writer never restarts the cluster; it waits for the
   next document.

6. **Verification.** The hardware-gated proof stops the production search writer
   for the duration, reboots the `search` guest, and restores the writer:

   ```sh
   /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-ingest-verify
   ```

   It must print `PASS round-trip`, `PASS secret`, `PASS dns`, `PASS sni`,
   `PASS egress`. Record the exact guest console lines if it fails.

7. **Logs.** Root-only file logs live in `/var/log/kanbei-ingest/`; guest consoles
   are the `microvm@<guest>` journal. Read them through the touch-gated sudo
   wrapper:

   ```sh
   /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs
   /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs writer-tuta
   ```

8. **Finance (Schwab and Chase).** Claim the SimpleFIN Access URL once, then
   stage it as `ingest-finance-env`:

   ```sh
   token='<base64 SimpleFIN token>'
   curl -X POST "$(printf '%s' "$token" | base64 -d)"   # prints the Access URL once
   umask 077
   printf 'SIMPLEFIN_ACCESS_URL=%s\n' "$access_url" > finance-env
   sudo install -m 0400 -o root -g root finance-env /run/secrets/ingest-finance-env
   sudo systemctl stop microvm@ingest-finance
   sudo systemctl start ingest-vm-secret-finance microvm@ingest-finance
   ```

   The Access URL embeds the SimpleFIN credentials; never paste it into a
   ticket or log. Both institutions are reached through MX, so an
   `act.missingdata` or `con.auth` alert means retry the institution in the
   Bridge, not a local bug. Plaid is off by default: to use it, set
   `ingestVm.financePlaid.enable = true`, add `PLAID_CLIENT_ID`,
   `PLAID_SECRET` and `PLAID_ITEMS_JSON` to the contract, then run
   `ingest-finance-plaid --env <env> --link-token` with the owner present to
   complete Plaid Link (Chase/Schwab OAuth is Production-only). Trial allows 10
   production Items, one approval per OAuth institution. Steps and keys:
   [`docs/kanbei-ingest-finance.md`](kanbei-ingest-finance.md).

9. **Brave Sync chain.** The guest profile needs one seed. Preferred: on a
   workstation already in the chain, close Brave and export
   `jq -r '."brave_sync"."v2"."seed"' ~/.config/BraveSoftware/Brave-Browser/Default/Preferences`,
   store it as `BRAVE_SYNC_SEED` in `ingest-brave-env`, and re-stage. Fallback:
   put the 25-word code in `BRAVE_SYNC_CODE`, start `brave-sync-join` inside the
   guest, and clear the code after it joins. Set a custom chain passphrase and
   store it in Bitwarden before relying on the chain; the 25-word code rotates
   daily. Do not add passwords or bookmarks to the chain — the accepted residual
   is that a compromised guest or stolen seed can copy every synced type to an
   attacker chain. Procedure: [`docs/kanbei-ingest-brave.md`](kanbei-ingest-brave.md).

10. **Immich metadata key.** Create a dedicated Immich API key with only
    `asset.read`, `album.read` and `person.read`, and stage
    `ingest-immich-env` with `IMMICH_API_KEY` (the base URL is pinned to
    `https://photos.sammohr.dev`). The guest can reach only that name through
    the host proxy/resolver; no cluster address is allowed. Confirm the first
    run pages the library once and later runs are incremental; the collector
    refuses every byte endpoint. Steps:
    [`docs/kanbei-ingest-immich.md`](kanbei-ingest-immich.md).

11. **Search guest: Kanbei's search key and the Guardian model.** The `search`
    guest holds Kanbei's only TinyFish key and the Granite Guardian judge.
    Mint a key dedicated to Kanbei (never the host's `tinyfish-api-key`) and
    stage the contract, which is exactly one line:

    ```sh
    umask 077
    printf 'TINYFISH_API_KEY=%s\n' '<kanbei search key>' > search-env
    sudo install -m 0400 -o root -g root search-env /run/secrets/ingest-search-env
    shred -u search-env
    ```

    The weights are data, not store content; fetch them on the host with the
    manifest that pins size and sha256:

    ```sh
    sudo nix shell nixpkgs#python3 -c \
      python3 modules/lib/kanbei-fetch-models.py \
        --manifest modules/lib/search-models.json \
        --dest /var/lib/search-model --uid 0 --gid 0
    sudo systemctl status search-vm-model search-vm-state search-relay microvm@search
    sudo iptables -S ingest-search-in ingest-search-fwd
    ```

    `search-vm-model.service` verifies the hash before building the read-only
    image; a missing key or model keeps the guest down instead of starting a
    permissive service. `search-vm-state.service` creates the 8 MiB writable
    image behind `/var/lib/search` once, so the rate/budget counters survive a
    restart; stop `microvm@search` and delete
    `/var/lib/microvms/search-state/state.img` to reset the budget on purpose.
    Every query and decision is root-only; read it through
    the touch gate with `kanbei-logs search`. The gate order, defaults, wire
    schema, measured suite thresholds and the real-model measurement procedure
    are in [`docs/kanbei-search.md`](kanbei-search.md).

### smorespro

<!-- manual-step: host/smorespro -->

Intel laptop (NixOS), the only graphical host: Niri, noctalia-greeter with the
YubiKey PIV as one prompt, and a LUKS root that the TPM unlocks with a PIN
under Secure Boot (`modules/hosts/smorespro/{boot,greeter,disko}.nix`). A fresh
install wipes the NVMe.

Prerequisites, all of them:

1. This host config is **on `main` and pushed**. `bootstrap` clones
   `github:smores56/nix-config` and rebuilds from it; booting the new machine
   from `main`'s pre-LUKS layout leaves it unable to mount its root.
2. `nix run .#key-backup` already ran on the old install and the bundle (which
   carries the host key) is in Bitwarden.
3. Run everything below from the **operator checkout on another machine**
   (smortress), never on the target: `nixos-anywhere` kexecs the target and the
   run dies with it.
4. Do **not** `nixos-rebuild switch` the old unencrypted install with this
   configuration: its initrd would look for a LUKS device that does not exist.

```sh
# 1. The host identity `install` delivers. install refuses without it, and an
#    installed machine without it cannot decrypt its own secrets.
nix run .#key-restore -- ~/Downloads/smorespro-restore-<time>.tar.gz --host-key

# 2. Wipes the disk, formats the LUKS root, installs. Needs a terminal: the
#    passphrase prompt is interactive, and a piped or empty value would become
#    the only keyslot. Keep the passphrase; it stays after the TPM is enrolled.
nix run .#install -- smorespro root@<target-ip>
```

`install` rewrites `modules/hosts/smorespro/hardware.nix`; commit the generated
file and re-apply hand-added lines (e.g. `hardware.cpu.intel.npu.enable`) before
step 4.

The first boot asks for that passphrase (no TPM key exists yet). Then, on the
new machine:

```sh
# 3. Prove the passphrase slot survived the format before trusting it.
sudo cryptsetup luksDump /dev/disk/by-partlabel/root   # exactly one keyslot

# 4. Recovery key: print it, store it off-site and in Bitwarden. Do this
#    before enrolling the TPM.
sudo systemd-cryptenroll --recovery-key /dev/disk/by-partlabel/root

# 5. Home config, FIDO2 handles, SSH (fresh installs have no checkout yet)
nix run github:smores56/nix-config#bootstrap
cd ~/repos/github.com/smores56/nix-config
nix run .#key-restore -- ~/Downloads/smorespro-restore-<time>.tar.gz
ssh smortress true   # one graphical YubiKey PIN prompt on first use
```

Secure Boot comes next, because the TPM step binds PCR 7, which measures the
Secure Boot policy (`db`): enrolling the TPM first leaves a keyslot that stops
unsealing the moment Secure Boot is turned on. The first boot generated this
machine's keys (`sbctl` service; plaintext only inside the LUKS root).

```sh
# 6. Sign the ESP with those keys and verify the signature before enrolling.
sudo nixos-rebuild boot --flake .#smorespro
sudo sbctl verify                    # every EFI binary "is signed"
sudo sbctl status                    # keys present, Secure Boot: Disabled

# 7. Reboot into the firmware (F2), set the supervisor password under Security,
#    then Administer Secure Boot → "Erase all Secure Boot Settings" to enter
#    setup mode (Framework's documented path; it deletes PK/KEK/db). Boot back
#    into NixOS and confirm `sbctl status` reports Setup Mode: Enabled and
#    Secure Boot: Disabled before enrolling:
sudo sbctl enroll-keys --microsoft --firmware-builtin   # also restores Framework's KEK/db

# 8. Reboot, turn **Enforce Secure Boot** on in the same firmware menu (enrolling
#    does not enable enforcement), then confirm:
bootctl status                       # Secure Boot: enabled (user)
```

`--microsoft` keeps Microsoft-signed option ROMs (and the vendor update path)
bootable; dropping it can leave the machine without video. `--firmware-builtin`
keeps the certificates the Framework firmware shipped with, which its own
updates are signed against. Never erase the `dbx`.

```sh
# 9. TPM + PIN, bound to PCR 7. The PIN is new: distinct from the YubiKey PIN
#    and from the account password. Wrong PINs count against the TPM lockout.
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs=7 /dev/disk/by-partlabel/root

# 10. Reboot and prove it: the TPM PIN prompt appears, the PIN boots, three
#     wrong PINs fall back to the passphrase, and the recovery key still opens
#     the root. Only then is the slot trustworthy.
```

`--tpm2-pcrs=7` is mandatory: systemd 258+ binds no PCRs unless asked, and an
unbound TPM slot unlocks on any machine that gets the disk. Never bind PCR 4,
which changes on every rebuild. The passphrase slot and the recovery key stay:
after a firmware update, a cleared fTPM, or a new `db`, re-enroll the TPM slot
with `sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto
--tpm2-with-pin=yes --tpm2-pcrs=7 /dev/disk/by-partlabel/root`, or unlock with
the recovery key.

Once the slot is enrolled, flip the install crutch off in
`modules/hosts/smorespro/boot.nix`: set `boot.lanzaboote.autoGenerateKeys.enable
= false` (that also restores `allowUnsigned = false`, so a missing key pair can
never silently install unsigned boot artifacts again), push, and on the machine
`git pull && sudo nixos-rebuild switch --flake .#smorespro`.

```sh
# 11. Fingerprint (greeter and lock screen; pam_fprintd is only on greetd,
#     never sudo, su, polkit-1, or login)
fprintd-enroll
fprintd-verify
fprintd-list "$USER"
```

YubiKey sudo has no sshd and no PIN: `pam_rssh` on the `sudo` stack dials the
sudo agent at `/run/user/1000/fido2-agent`, which `fido2-agent-load`
fills with the three touch-only handles at login. Verify with the key inserted:
`sudo -v` shows `Please touch the device`, one touch succeeds, and a second
`sudo -v` inside five minutes does nothing. With the handles gone
(`SSH_AUTH_SOCK=/run/user/1000/fido2-agent ssh-add -D`) or no key present,
`sudo` falls back to the account password. `id -u` must already be `1000`
before the first switch that ships this configuration: the socket path is
derived from the pinned uid, and renumbering an existing account does not
chown `$HOME`.

Login and unlock attempt a factor only when it can succeed:

- **Greeter:** lid gate → `pam_fprintd` (`timeout=5 max-tries=1`) → CCID gate →
  `pam_p11` → `pam_unix`. A closed lid skips the fingerprint; no reader skips
  the PIV path, so the password is the first prompt.
- **Lock screen (Noctalia):** fingerprint over D-Bus starts on lock, after a
  failed password, and on resume; it never blocks the password path. PAM against
  `login`: CCID gate → `pam_p11` → `pam_unix`. The text console shares `login`.
- **`pam_p11` control** is `[success=done authinfo_unavail=ignore default=die]`:
  a correct PIN stops the stack (exactly one prompt); `AUTHINFO_UNAVAIL` (no
  matching certificate, a locked PIV, or pcscd down) falls through to the
  password; a wrong PIN or non-PIN text denies, so a typed password never
  reaches the card and never burns a retry.

The gates are `pam_exec` probes built with `pkgs.writeShellApplication` (store
paths that own their `PATH`). `pam_exec` passes an **empty** environment, so a
bare command exits 127 and the gate silently no-ops. The card probe is a build
input because a missing one runs `pam_p11` and its `default=die` would lock out
the password entirely. `pam-auth-gates` pins both full stacks and asserts
`sudo`/`su`/`polkit-1` carry no `p11`/`fprintd`/`exec`.

The greeter does not rate-limit PIV attempts: anyone at the unlocked-room
greeter can burn the eight-try budget. A locked PIN now falls back to the
password, but treat "PIN blocked" as a physical-access signal. Keep the key
with you.

Post-change verification: lid closed + key out → password in ≤200 ms; lid open
→ fingerprint; lid open + key out → ~5.4 s then password; the seven-case
one-prompt matrix passes including a wrong password; and
`nix build .#checks.x86_64-linux.pam-auth-gates` stays green.

Maki's personal profile on this host reads `NEURALWATT_API_KEY` and
`TINYFISH_API_KEY` from `secrets/common.yaml`, which names smorespro as a
recipient.

#### Discord

The Discord package carries Vencord so Stylix's generated theme applies. After
the first home-manager switch, enable `stylix.theme.css` once in Discord's
Vencord settings → Themes. Vencord owns
`~/.config/Vencord/settings/settings.json`, so the repo does not manage it.

#### NymVPN

NymVPN is an outbound client on this host. It exposes nothing and does not
replace the Cloudflare Tunnel. The root daemon is `nym-vpnd`; run `nym-vpnc`
through `sudo`. There is no passwordless group and no polkit policy: an
unprivileged process is refused, and `ProtectSystem` keeps `/usr` and `/etc`
read-only so the daemon cannot install its polkit fallback. A process sharing
this user's TTY can still reuse a live sudo ticket (five minutes), so treat
that window as trusted.

Create the account once at <https://nym.com/account/create> and store the
24-word access code in Bitwarden plus an offline copy. Do not put the phrase in
sops, Syncthing, or a backup of `/var/lib/nym-vpnd` (account and config). Enter
it inside `start-session`, never as a `sudo` argument: sudo logs argv, and argv
is readable from `/proc` by every local process.

```sh
# One-time device login. The phrase goes to the session, not argv or history.
sudo nym-vpnc start-session
# At the session prompt (not your shell):
account set "<24 words>"
account get
exit

# Daily use. Mixnet (two-hop off) is the working mode; Fast/two-hop fails on
# Linux with `sendmmsg: operation not permitted` (upstream #6303). A fresh
# /var/lib/nym-vpnd defaults to two-hop on, so set this before the first connect.
sudo nym-vpnc tunnel set --two-hop off
sudo nym-vpnc connect --wait
sudo nym-vpnc status
getent hosts example.com
cat /etc/resolv.conf        # only Nym's loopback resolver while connected

# Syncthing and printers need the LAN at home; block it on untrusted Wi-Fi.
sudo nym-vpnc lan set allow
# sudo nym-vpnc lan set block

# Captive portal: disconnect, sign in, then reconnect.
sudo nym-vpnc disconnect --wait
```

`dns get` prints only the custom-DNS setting; read `/etc/resolv.conf` to see the
resolver actually applied. The unit removes stale `*.nym` resolvconf records and
the nftables table on start and stop, so no manual cleanup is needed. If a
killed stop still leaves networking broken, confirm `nym-vpnd` is stopped and
run `sudo nft delete table inet nym` (deleting it while connected removes the
kill switch).

Fish abbreviations on this host: `nv` = `sudo nym-vpnc`, `nvc` = `connect
--wait`, `nvd` = `disconnect --wait`.

Phone (Galaxy S24 Ultra): install NymVPN from Google Play, sign in with the
same 24-word code, then Settings → Kill switch → enable Android's Always-on VPN
and Block connections without VPN. Set battery to Unrestricted, keep Private
DNS on Automatic, and turn Samsung Secure Wi-Fi off. Split tunneling is Fast
mode only.

### smoreswork

<!-- manual-step: host/smoreswork -->

The employer's macOS laptop (home-manager only; no NixOS configuration). Install
Nix, then:

```sh
nix run github:smores56/nix-config#bootstrap
```

`bootstrap` derives the configuration name from the machine's hostname and
user; on a laptop whose OS hostname is not `smoreswork`, override both:
`BOOTSTRAP_USER=sam BOOTSTRAP_HOST=smoreswork ...`.

MDM enrollment, FileVault, and OS updates stay with the employer; this repo only
manages the user environment. The memory instance additionally needs Docker
Desktop (set to start at login) and Claude Code installed at
`~/.local/bin/claude` and signed in; see
[smoreswork/memory](#smoreswork-memory-instance).

The weekday `harvest` (launchd, 17:30) reads Jira through `acli` (Homebrew
`atlassian/acli/acli`, logged in with `acli jira auth login`) and PRs through `gh`.
Calendar and Granola titles are not harvested: the `brain` skill fetches them
when you ask for a standup. A source that is not logged in
is reported in the run's notification and retried the next day; `harvest
dry-run` previews what a run would write.

The GUI apps come from Homebrew, not nix. `just brew-bundle` installs the casks
in `modules/features/brew.nix` (kitty and AeroSpace among them) from the
Brewfile home-manager writes to `~/.config/homebrew/Brewfile`. It only adds:
packages the file omits are never uninstalled, and the employer's own are not
declared. Home-manager switches never run brew.

## Tang Pi

smortress's root disk gets a Clevis `sss` policy (Tang share + TPM2 share bound
to PCR 7). The Pi is not a NixOS host in this flake: it runs
Raspberry Pi OS (Debian trixie, aarch64) and only `tang`.

Threat model: Tang keys are plaintext on the Pi. A stolen disk alone, a live USB
on the LAN, or a Secure-Boot-off boot cannot unseal the TPM share; a thief who
takes the server and the Pi together decrypts. Keep the Pi patched, on the LAN
only, and never forward the Tang port through Cloudflare or the router.

Current server:

```
Address:     10.0.0.193/24 on wlan0 (DHCP reservation for b8:27:eb:29:b8:4d)
WiFi:        NetworkManager profile SmoresNet (/etc/NetworkManager/system-connections/)
Tang:        15-2, listening on TCP 7654
Keys:        /var/lib/tang, user _tang
Allowlist:   127.0.0.1/32, 10.0.0.125/32, 10.0.0.135/32
             (smortress wired and wireless; route to the Pi uses 10.0.0.125)
```

### Install

```sh
sudo apt install -y tang
sudo systemctl enable --now tangd.socket
```

The trixie package installs the upstream units, which default to port **80**
and `/var/lib/tang`. Override the port so the URL matches the Clevis step (the
empty assignment resets the list first):

```sh
sudo mkdir -p /etc/systemd/system/tangd.socket.d
sudo tee /etc/systemd/system/tangd.socket.d/port.conf >/dev/null <<'EOF'
[Socket]
ListenStream=
ListenStream=7654
EOF
sudo systemctl daemon-reload && sudo systemctl restart tangd.socket
```

### Restrict to smortress

Raspberry Pi OS ships no enabled firewall (no `ufw`, no `nft`). Restrict the
socket and the per-connection service with systemd address filtering. Loopback
must stay allowed or the local check below fails; both smortress interfaces are
listed so a dead Ethernet link does not turn every boot into a passphrase
prompt:

```sh
sudo mkdir -p /etc/systemd/system/tangd.socket.d \
  /etc/systemd/system/tangd@.service.d
sudo tee /etc/systemd/system/tangd.socket.d/allow.conf >/dev/null <<'EOF'
[Socket]
IPAddressDeny=any
IPAddressAllow=127.0.0.1/32 10.0.0.125/32 10.0.0.135/32
EOF
sudo tee /etc/systemd/system/tangd@.service.d/allow.conf >/dev/null <<'EOF'
[Service]
IPAddressDeny=any
IPAddressAllow=127.0.0.1/32 10.0.0.125/32 10.0.0.135/32
EOF
sudo systemctl daemon-reload && sudo systemctl restart tangd.socket
```

Verify on the Pi that loopback answers and a non-allowlisted source does not:

```sh
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7654/adv   # 200
curl -s -m 3 --interface 10.0.0.193 -o /dev/null -w '%{http_code}\n' \
  http://10.0.0.193:7654/adv                                          # 000
```

Then from smortress: `curl -sf http://10.0.0.193:7654/adv`.

### SSH access

The Pi sits where attaching a keyboard and monitor is painful, so SSH is
key-only and the console password is only the recovery path. Stock Raspberry Pi
OS allows passwords and root; `/etc/ssh/sshd_config.d/10-hardening.conf`:

```sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers smores
AuthenticationMethods publickey
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
MaxAuthTries 10
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
```

`~smores/.ssh/authorized_keys` holds only the three YubiKey PIV 9a public keys
from `modules/lib/yubikey-keys.nix`. `modules/features/piv.nix` defines
`Host tang-pi` (HostName 10.0.0.193) on both laptops: `piv-ensure` warms the PIV
agent first (one PIN per login session), then `nc` connects. Pin the host key
once per laptop;
`SSH_ASKPASS_REQUIRE=force` sends the `yes/no` prompt to the session askpass,
which fails closed on everything but a password prompt, so the first connection
fails until this is done:

```sh
echo '10.0.0.193 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAQcI4/G5fQWGgkF1s7zkhWrXz/64LWeUJYh3SB231B2' \
  >> ~/.ssh/known_hosts
ssh-keygen -lf ~/.ssh/known_hosts | grep 10.0.0.193   # SHA256:fulskYo5kn62Xn9qgIiqtIexW3WLgg1QONyjDelnInM
```

`sudo` still prompts for the `smores` account password (a second factor after
the key), and root has no `authorized_keys`. If every key is lost, the console
password still boots and logs in; do not remove the password slot.

### Record the values

These are public (Tang advertises them on `/adv`); they are recorded so the
Clevis step can check trust-on-first-use and confirm a re-bound JWE still points
at the same server. `tang-show-keys` on the Pi prints one thumbprint per key:

```
Tang URL: http://10.0.0.193:7654
tang-show-keys 7654 output:
  rnazNy47pX3hb89qAYeyQkE8YeF0oWY60XTgUEnXKr8
```

The package generated the two keys (`ES512` verify, `ECMR` derive) under
`/var/lib/tang` at first start. If the Pi is rebuilt its keys change: re-run the
Clevis bind with the LUKS passphrase. Do not back the Tang keys up as
a way to avoid that; the passphrase slot plus the offline recovery key are the
recovery path.

## Secrets

Secrets are split by scope:

- `secrets/smortress.yaml` — host-only material for smortress (Cloudflare token,
  tunnel JSON, calibre password, the mirror's repo PAT), encrypted to the
  admin identity plus the smortress host key.
- `secrets/smorespro.yaml` — host-only material for smorespro. Its age identity
  is the SSH host key smorespro keeps solely for sops, since it runs no sshd.
- `secrets/smoreswork.yaml` — host-only material for the work Mac. It has no
  sshd host key, so its identity is a dedicated age key at
  `~/.config/sops/smoreswork.key` (`sops.age.keyFile`); sops-nix cannot prompt
  for a passphrase at home-manager activation, so that file stays unwrapped and
  `0600`. Provisioning is in *smoreswork sops key* below.
- `secrets/common.yaml` — cross-host user secrets (neuralwatt, tinyfish, the
  `smores` password hash, owner-scoped PATs), encrypted to the admin identity
  plus every host's key (`smortress`, `smorespro`, `smoreswork`). Each of those
  hosts can read the whole file, so host-only keys must not go in it.

Every machine holds the admin identity (passphrase-wrapped), so edit anywhere:

```sh
sops secrets/smortress.yaml
sops secrets/common.yaml
```

`sops` and `age` come from `modules/features/sops.nix`, which also points
`SOPS_AGE_KEY_CMD` at the `sops-age-key` wrapper. After editing, commit and run
`sudo nixos-rebuild switch` on smortress so sops-nix redeploys `/run/secrets`.
Never place a secret in the Nix store.

### Admin age key (keys.age)

The admin identity is a single age key, stored passphrase-encrypted as
`~/.config/sops/keys.age` on every machine (smortress, smorespro, smoreswork).
It is a recipient of every file in `secrets/`, so any machine holding it can
read and re-encrypt the whole tree. NixOS hosts still decrypt at boot with
their SSH host keys, which is why losing `keys.age` does not stop a running
host.

`sops` receives the identity through `SOPS_AGE_KEY_CMD` → `sops-age-key` →
`age --decrypt ~/.config/sops/keys.age`. `age` prompts on the tty and sops reads
the identity from the wrapper's stdout, so the passphrase never lands in argv,
the environment, or the store, and one sops run costs one prompt.

Create it once, then copy the encrypted file to every machine:

```sh
mkdir -p ~/.config/sops
(umask 077; age-keygen | age --passphrase -o ~/.config/sops/keys.age)
age --decrypt ~/.config/sops/keys.age | age-keygen -y   # prints the recipient
```

`age` creates the file `0644`; the subshell's `umask` keeps it `0600`.

Copy the encrypted file to every other machine as-is (the passphrase travels
separately). Put the recipient into `.sops.yaml` as `&admin`, then re-encrypt
the data key to the new recipient list:

```sh
sops updatekeys secrets/smortress.yaml   # one prompt; values are untouched
```

Repeat for every file the admin identity should read (`smorespro.yaml`,
`common.yaml`, and, from the Mac, `smoreswork.yaml`), or the omitted recipient
stanza is pruned from that file.

`updatekeys` re-wraps only the *data key*: an identity that already unwrapped
it keeps decrypting every current and future value. After the recipient swap,
rotate the data key itself so the retired identity is useless:

```sh
sops rotate --in-place secrets/smortress.yaml   # new data key, same values
```

Verify the machine holds a working identity:

```sh
sops -d secrets/smortress.yaml > /dev/null   # one prompt, exit 0
```

**Every machine.** Confirm each one has the file and a working identity:

```sh
test -e ~/.config/sops/keys.age
sops -d secrets/smortress.yaml >/dev/null   # one prompt, exit 0
```

The wrapper refuses to run while a plaintext `~/.config/sops/age/keys.txt`
exists, because sops would load that default even with `SOPS_AGE_KEY_CMD` set.

**Passphrase custody.** Bitwarden plus an off-site copy on offline media. Keep
the encrypted file and the passphrase apart; either alone is worthless. Every
machine carries the same encrypted file, so those copies die with their disks.
Losing both means losing the identity — nothing can unwrap `keys.age`. The
secrets themselves survive (host keys still decrypt their host files), so
recovery is minting a new identity and re-keying (below), not restoring the old
one.

**Editing rule.** Every `sops` edit and `sops updatekeys` runs from any machine
holding `keys.age`; all of them can read the whole tree. On smortress, commit
and `sudo nixos-rebuild switch` after editing so sops-nix redeploys
`/run/secrets`. The wrapper's message is printed on the terminal, because sops
swallows the command's stderr. `SOPS_AGE_KEY_CMD` is a session variable, so
reopen a shell that predates the last switch.

**Replace the admin identity** (also the path after a lost passphrase or a
suspected leak):

1. Mint a new `keys.age` (above) and swap the `&admin` recipient in
   `.sops.yaml`.
2. Re-encrypt the data key to the new recipient list, then rotate the data key,
   for every file (`smortress.yaml`, `smorespro.yaml`, `common.yaml`,
   `smoreswork.yaml`). Any identity that can still decrypt a file works; each
   host key covers its own files, and `smoreswork.yaml` needs the Mac's
   `~/.config/sops/smoreswork.key` via `SOPS_AGE_KEY_FILE`. From a machine that
   still holds the old identity:
   ```sh
   sops updatekeys secrets/smortress.yaml
   sops rotate --in-place secrets/smortress.yaml
   ```
   If that identity is gone (lost passphrase), the host key is the only way in.
   The substitution must run inside `sudo` — the host key is root-only, and
   `$(...)` would otherwise run as your user and yield an empty key:
   ```sh
   sudo nix shell nixpkgs#sops nixpkgs#ssh-to-age -c sh -c '
     export SOPS_AGE_KEY="$(ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)"
     sops updatekeys -y secrets/smortress.yaml
     sops rotate --in-place secrets/smortress.yaml'
   sudo chown "$USER" secrets/smortress.yaml
   ```
   Either path drops the old recipient stanza and gives the values a new data
   key, so the old identity can no longer decrypt them.
3. Prove it while the old key still exists — the recipient list is readable
   without decrypting, and sops tries every identity source it can find, so
   drop the wrapper for the negative test:
   ```sh
   grep -o 'age1[0-9a-z]*' secrets/smortress.yaml | sort -u   # new admin + host only
   env -u SOPS_AGE_KEY_CMD SOPS_AGE_KEY="$(cat ~/.config/sops/age/keys.txt)" \
     sops -d secrets/smortress.yaml > /dev/null               # must fail
   ```
4. Delete the plaintext `~/.config/sops/age/keys.txt` on every host and user
   (`rm ~/.config/sops/age/keys.txt`). sops reads that path as a built-in
   default even when `SOPS_AGE_KEY_CMD` is set, so a leftover copy keeps
   decrypting with the retired key.
5. Re-encryption and the data-key rotation do not un-leak what the old key
   already read: rotate every credential in the checklist below.
6. Commit and rebuild smortress. The host recipient is unchanged, so secret
   delivery needs no host change.

### smoreswork sops key

The work Mac needs an identity at home-manager activation, which cannot prompt,
so it keeps a plaintext host identity (`~/.config/sops/smoreswork.key`) in
addition to the passphrase-wrapped `keys.age` used for interactive sops. The
host identity's recipient is `&smoreswork` in `.sops.yaml`.

```sh
mkdir -p ~/.config/sops
(umask 077; age-keygen -o ~/.config/sops/smoreswork.key)
age-keygen -y ~/.config/sops/smoreswork.key      # must match &smoreswork
chmod 600 ~/.config/sops/smoreswork.key
```

Copy the file to the Mac unchanged and delete any intermediate copy: without a
passphrase, that file *is* the key. Before the first switch, prove it is a
recipient and that the file is committed:

```sh
SOPS_AGE_KEY_FILE="$HOME/.config/sops/smoreswork.key" \
  sops -d secrets/smoreswork.yaml >/dev/null
git add secrets/smoreswork.yaml     # flakes only see tracked files
```

A missing or wrong key does not fail `darwin-rebuild switch`: sops-nix runs from
a LaunchAgent there. After switching, check `ls ~/.config/sops-nix/secrets` and
`~/Library/Logs/SopsNix/stderr`.

A new recipient in a creation rule does not re-wrap an existing file. After
adding `&smoreswork` to the common rule, run
`sops updatekeys secrets/common.yaml` (one admin prompt) and commit the result,
or the Mac cannot decrypt that file.

### phone-folder-password

<!-- manual-step: secret/phone-folder-password -->

The password for the phone's Syncthing receive-encrypted folder. It is created
on the phone when the untrusted folder is set up, must equal the password typed
there, and is never stored anywhere else in plaintext: the host keeps only this
sops value, and the guest stages it into the LUKS volume for the hourly
`syncthing-decrypt` run.

Rotate it by creating a new folder password on the phone, saving it here
(`sops secrets/smortress.yaml`), and restarting `kanbei-phone-password.service`
and `syncthing-decrypt.service` on smortress. If the phone is lost, revoke its
Syncthing device and share the new folder password only with the replacement
device.

### cloudflare-api-token

<!-- manual-step: secret/cloudflare-api-token -->

One root-only token shared by OpenTofu and the email alert sender. Mint it at
<https://dash.cloudflare.com> → My Profile → API Tokens with:

- Zone:DNS:Edit for `sammohr.dev`;
- Zone:Rulesets:Edit for `sammohr.dev` (the public-app rate-limit ruleset);
- Access: Apps and Policies:Edit;
- Notifications:Edit;
- Email Sending:Edit;
- Workers R2 Storage:Edit on the account (`cloudflare_r2_bucket_cors` sets the
  bucket policy the recovery page needs; without it the apply fails with
  `403 Forbidden` / `Authentication error` on `PUT .../r2/buckets/*/cors`).

Readers: `nix run .#cloudflare-*` and the `cloudflare-email` unit. Rotate in the
dashboard, update this key, rebuild, and prove it with
`sudo nix run .#cloudflare-plan`.

### cloudflared-credentials

<!-- manual-step: secret/cloudflared-credentials -->

The tunnel credentials JSON (`TunnelID`, `TunnelSecret`, `AccountTag`). The
`TunnelID` field is the authoritative tunnel UUID used by OpenTofu; no UUID is
authored in the repo and `webProxy.tunnelName` is only a label.

Create or reissue the tunnel under Zero Trust → Networks → Tunnels and paste the
JSON here. Changing the tunnel means rebuilding the host and re-running
`cloudflare-apply`.

**Adopting existing objects.** An apply against an account that already has the
wildcard CNAME or the Access applications fails with `81053`/`11010`
("already exists"): those objects predate OpenTofu and must be imported, not
recreated. Import IDs are `<zone_id>/<record_id>` for the record and
`accounts/<account_id>/<app_id>` for applications:

```sh
sudo nix run .#cloudflare-tofu -- import cloudflare_dns_record.wildcard '<zone_id>/<record_id>'
sudo nix run .#cloudflare-tofu -- import cloudflare_zero_trust_access_application.ssh 'accounts/<account_id>/<app_id>'
```

List the IDs from `/zones/<zone>/dns_records` and
`/accounts/<account>/access/apps`; the access policies and notification policies
are normally in state already. The account ID comes from
`CLOUDFLARE_ACCOUNT_ID`, then `/etc/cloudflare-tofu/account-id`, then the
credentials JSON's `AccountTag`; the app exits rather than send an empty value,
which otherwise surfaces as `missing required account_id parameter` midway
through an apply.

### cloudflare-access-ssh-token

<!-- manual-step: secret/cloudflare-access-ssh-token -->

Per-host Cloudflare Access service token: one credential behind two clients.
`cloudflared-access` (`modules/features/cloudflared.nix`) reads it as
`TUNNEL_SERVICE_TOKEN_ID` and `TUNNEL_SERVICE_TOKEN_SECRET` for
`cloudflared access ssh`; `chat-proxy` (`modules/features/chat-proxy.nix`) reads
it as `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` so the browser reaches
`agent.sammohr.dev` without the Access one-time-PIN page. The value is two lines:
the client ID, then the client secret. Both wrappers read it only from the
host's sops deployment: `/run/secrets/cloudflare-access-ssh-token` from sops-nix
on NixOS, and the sops-nix user path on Darwin. A missing, unreadable or
malformed file is a hard failure in either; there is no cache or
password-manager fallback.

A NixOS declaration must hand the user access (`owner`/`mode`), because the
proxy runs as the user; `modules/hosts/smorespro/secrets.nix` is the example.

Mint one token per client machine under Zero Trust → Access → Service Auth, then
paste both lines as `cloudflare-access-ssh-token` in that host's file
(`secrets/smorespro.yaml`, `secrets/smoreswork.yaml`). That single token makes
the machine blessed: `cloudflared` and the chat proxy both read it, so the
browser opens `http://127.0.0.1:8787` on that device. To revoke one machine,
delete its token in Zero Trust → Access → Service Auth; its cloudflared forwards
and chat proxy then fail closed (the email OTP policy still serves humans). The
`service_auth` policy accepts any valid service token, so minting a token needs
no `cloudflare-apply` (the chat application's own policy change does); the
`expiring_service_token_alert` notification covers expiry.

Rotation and revocation: replace the two lines in the host's sops file, re-deploy
it (`just switch smorespro`, or `just home-switch sam smoreswork`), then restart
the unit so the clients re-read it: `systemctl --user restart chat-proxy` on
NixOS, `launchctl kickstart -k gui/$(id -u)/org.nix-community.home.chat-proxy` on
the Mac. Both clients
read the token only at start, so a re-deploy alone leaves a running proxy sending
the old value; a token deleted in the dashboard is rejected by the edge at once.

### github-repo-pat

<!-- manual-step: secret/github-repo-pat -->

Retired with the nix-config mirror (T9): the nightly ghorg/python-github-backup
units are gone, and the `homelabs-platform` CronJob owns GitHub mirroring with
its own fine-grained, read-only PAT. This repository declares no
`github-repo-pat` sops secret; `modules/nixos/kanbei-cutover.nix` fails
evaluation if a mirror unit or the declaration comes back.

The encrypted key is still in `secrets/smortress.yaml` because a sops edit
needs the YubiKey age key. On the next secrets session:

```sh
sops secrets/smortress.yaml          # delete the github-repo-pat key
sops updatekeys secrets/smortress.yaml
```

Then revoke the classic `repo`-scoped PAT at GitHub → Settings → Developer
settings → Personal access tokens. Until both steps run, the value is inert:
nothing reads `/run/secrets/github-repo-pat` and no unit declares it.

### smores-password-hash

<!-- manual-step: secret/smores-password-hash -->

SHA-512 crypt hash of the `smores` account password, in `secrets/common.yaml`.
Root-owned and `neededForUsers`, so sops-nix decrypts it before the users
activation; `users.mutableUsers = false` makes the declared hash win on every
rebuild (a manual `passwd` cannot drift it). The plaintext password is off-site
only.

Validate a candidate hash without exposing the password:

```sh
read -rsp 'hash: ' hash; echo
salt=$(printf '%s' "$hash" | cut -d'$' -f3)
read -rsp 'password: ' pw; echo
printf '%s' "$pw" | nix run nixpkgs#mkpasswd -- -m sha-512 -s -S "$salt" | grep -qxF "$hash" && echo MATCH
```

After deploying, `sudo passwd -S smores` must show `P`; `su - smores` from a
console proves the password before auto-login is removed.

### github-personal-pat

<!-- manual-step: secret/github-personal-pat -->

Fine-grained, **owner-wide** PAT for `smores56`, user-readable in
`secrets/common.yaml`. Consumed by `github-credential-helper` and the
PAT-aware `gh` wrapper (`modules/features/github-credentials.nix`) for HTTPS git
and `gh`; the wrapper selects personal/work by the target repo's owner (rule in `modules/features/github-credentials.nix`) and an explicit
`GH_TOKEN` overrides it. NixOS reads it from `/run/secrets`; the work Mac reads
the same common-file secret through home-manager sops
(`modules/hosts/smoreswork/sops.nix`). Permissions: Contents RW, Pull requests
RW, Issues RW, Metadata R — no SSH-key or signing-key permissions. Expires in
90 days; mint a replacement, update the common file, rebuild every host,
revoke the old token.

### github-personal-signing-key

<!-- manual-step: secret/github-personal-signing-key -->

The personal account's ed25519 commit-signing key, user-readable 0400 in
`secrets/common.yaml`, so every host (and the agent sandbox) signs as
`sam@sammohr.dev` with no agent or PIN. git names it as `user.signingkey`
(`modules/features/git.nix`): `/run/secrets/github-personal-signing-key` on
NixOS, sops-nix's default user path on the work Mac. The public half is `personal` in `modules/lib/signing-keys.nix`; it is
registered on `smores56` as a **signing** key only, and smortress also accepts
it as the laptop sandbox's forced-command login (`modules/nixos/ssh.nix`).

Rotate after losing any host:

```sh
d=$(mktemp -d) && trap 'rm -rf "$d"' EXIT
ssh-keygen -q -t ed25519 -N '' -C 'sam@sammohr.dev github-personal-signing-key' -f "$d/key"
jq -Rs . <"$d/key" | sops set --value-stdin secrets/common.yaml '["github-personal-signing-key"]'
cat "$d/key.pub"
```

Put the new public half in `modules/lib/signing-keys.nix`, register it on the
account (Settings → SSH and GPG keys → New SSH key, type **Signing Key**),
rebuild every host, then delete the old signing key on GitHub. Commits GitHub
already verified stay Verified. A leaked copy of this key also opens smortress's
forced sandbox login from anywhere the Access token works, so rebuild smortress
first when rotating after a suspected leak.

If a commit on the work Mac fails with `Couldn't load public key` or
`No such file`, macOS purged the decrypted secrets under `$TMPDIR`; re-run the
decrypt agent with
`launchctl kickstart -k gui/$(id -u)/org.nix-community.home.sops-nix`.

### github-work-pat

<!-- manual-step: secret/github-work-pat -->

The work account's token, in `secrets/smoreswork.yaml`: the work bundle exists
only on the work Mac. It is a **classic** PAT, because a fine-grained token
reaches one owner and work spans every owner in `user.work.githubOwners`.
Create it signed in as the work account: Settings → Developer settings →
Personal access tokens → Tokens (classic), scopes `repo`, `read:org` and
`workflow`, 90-day expiry; if the token list then shows **Configure SSO** for
it, authorize every work org. Store it with

```sh
read -rs T && printf '%s' "$T" | jq -Rs . | sops set --value-stdin secrets/smoreswork.yaml '["github-work-pat"]'; unset T
```

and verify from any directory that both orgs answer, for example
`git ls-remote https://github.com/<owner>/<repo>.git` once per work owner.
The credential helper and `gh` wrapper select it from the repository owner, so
work and personal tokens never mix; on a personal host a work repo has no token
(the helper answers nothing and `gh` refuses with the owner named), and the
personal token is never substituted. Rotate on the same 90-day cadence, then
revoke the old token.

### github-work-signing-key

<!-- manual-step: secret/github-work-signing-key -->

The work account's ed25519 commit-signing key, in `secrets/smoreswork.yaml`
only. The work owner include selects it there; personal hosts have no work
key, so a work commit there signs with the personal key and shows Unverified.
The public half is `work` in `modules/lib/signing-keys.nix`, registered on the
work account as a **signing** key only. Rotate as for
`github-personal-signing-key`, writing to `secrets/smoreswork.yaml` and
rebuilding only the work Mac.

### neuralwatt-api-key

<!-- manual-step: secret/neuralwatt-api-key -->

Hosted-inference key in `secrets/common.yaml`, user-readable on every NixOS
host, exported by the fish init as `NEURALWATT_API_KEY` for maki's provider
config. Rotate in the Neuralwatt console, update the common file, rebuild each
host, and open a new shell.

### tinyfish-api-key

<!-- manual-step: secret/tinyfish-api-key -->

Web search key in `secrets/common.yaml`, user-readable on every NixOS host,
exported by the fish init as `TINYFISH_API_KEY` for maki's `websearch` tool.
Rotate at [agent.tinyfish.ai](https://agent.tinyfish.ai/api-keys), update the
common file, rebuild each host, and open a new shell.

### openai-api-key

<!-- manual-step: secret/openai-api-key -->

The employer's OpenAI key in `secrets/smoreswork.yaml` only, for the work Mac's
memory embeddings. Rotate it in the employer's OpenAI console, then
`sops secrets/smoreswork.yaml`, commit, and `home-manager switch`; the memory
LLM proxy reads the key once at start, so
`launchctl kickstart -k gui/$(id -u)/org.nix-community.home.memory-llm-proxy`
picks up a rotation. Agents on the Mac are unsandboxed and could read it; never
print or decrypt it in a session.

### restic repository password

<!-- manual-step: secret/restic-password -->

Random 32 bytes (`openssl rand -base64 32`), stored in `secrets/smortress.yaml`
(root 0400), in Bitwarden, and on the offline paper. Losing all three copies
loses the backups. Rotation: update the value and rebuild.

### R2 access key id and secret

<!-- manual-step: secret/r2-access-key-id -->
<!-- manual-step: secret/r2-secret-access-key -->

Create a Cloudflare R2 API token scoped to the `restic-backup` bucket with
Object Read & Write. Put the id and secret in `secrets/smortress.yaml`; the
restic unit reads them through the sops template `restic-r2.env`.

<!-- manual-step: secret/r2-access-key-id-readonly -->
<!-- manual-step: secret/r2-secret-access-key-readonly -->

A second token, scoped Object Read only, backs read-side consumers. Put its id
and secret in `secrets/smortress.yaml` as `r2-access-key-id-readonly` and
`r2-secret-access-key-readonly`.

### Memory MCP token

<!-- manual-step: secret/memory-mcp-token -->

Random 32 bytes in `secrets/common.yaml`, user-readable 0400. Presented as
`Authorization: Bearer` by Maki and the memory CLI/shim. Rotation requires
restarting `memory-mcp` and Maki.

### Rotation checklist

The retired admin key could read every value here, so re-encryption alone is
not enough — rotate the upstream credential too. Per item: mint the new
credential, `sops secrets/smortress.yaml`, commit, `sudo nixos-rebuild switch`
on smortress, prove it, then revoke the old one. The tunnel credentials are the
one item that is not a plain token swap.

#### cloudflare-api-token

Dashboard only (My Profile → API Tokens → Create Token, scopes above; there is
no CLI minting). Then:

```sh
sops secrets/smortress.yaml          # replace cloudflare-api-token
sudo nixos-rebuild switch            # redeploys /run/secrets/cloudflare-api-token
sudo nix run .#cloudflare-plan       # proves the new token
```

Delete the old token row. `cloudflare-email@` reads the file at run time, so no
unit restart is needed.

#### github-repo-pat

Retired (T9). The mirror is the `homelabs-platform` CronJob's; rotate its
read-only PAT there. For this repo the only remaining action is the one-time
cleanup above: delete the encrypted key, then revoke the classic PAT. There is
no mirror unit to restart.

#### neuralwatt-api-key

Mint a new key in the Neuralwatt console and revoke the old one there (web).
Replace the secret and rebuild; sops-nix restarts `memory-llm-proxy.service`
through the secret's `restartUnits`, so the gateway picks the new key up:

```sh
sops secrets/common.yaml
sudo nixos-rebuild switch        # on smortress and smorespro
```

Open a new shell for `NEURALWATT_API_KEY` (the fish init exports it at shell
start), and restart any agent session that cached the old key.

#### tinyfish-api-key

Mint a new key at [agent.tinyfish.ai](https://agent.tinyfish.ai/api-keys) and
revoke the old one there (web). Replace the secret and rebuild every NixOS
host:

```sh
sops secrets/common.yaml
sudo nixos-rebuild switch        # on smortress and smorespro
```

Open a new shell for `TINYFISH_API_KEY` (the fish init exports it at shell
start), and restart any agent session that cached the old key.

#### cloudflared-credentials

cloudflared has no `rotate-secret` subcommand, and the dashboard's Refresh token
is not known to reissue a `TunnelSecret` for this locally-managed tunnel, so
recreate the tunnel — from the console, since the tunnel is the only path to
the host. `AccountTag` stays (it is the Cloudflare account); `TunnelID`
and `TunnelSecret` change:

1. Create the tunnel in Zero Trust → Networks → Tunnels (dashboard: Networking
   → Tunnels), keeping `webProxy.tunnelName` as the label; `cloudflared tunnel
   create smortress` from a laptop with `cloudflared tunnel login` does the same
   and writes `~/.cloudflared/<uuid>.json`.
2. Paste the new JSON into `cloudflared-credentials` and rebuild. Do not
   restart cloudflared yet: SSH is tunnel-only, so restarting before DNS moves
   strands you without a console.
3. The `TunnelID` changed, so re-point DNS first: `sudo nix run .#cloudflare-plan`,
   review, then apply. The old connector keeps serving its hostnames until it
   restarts.
4. `sudo systemctl restart cloudflared-tunnel-smortress`, then confirm SSH and
   the LLM/OPDS hostnames still answer.
5. Delete the old tunnel and its DNS records.

## Wallpapers (smorespro, smoreswork)

`modules/features/wallpapers.nix` rsyncs `/var/lib/data/wallpapers` from smortress
into `~/.cache/wallpapers`, buckets every image by measured pixels (2:1 or
wider is ultrawide), and sets one image per display, picked at random from that
aspect's queue: nothing repeats until the aspect's set is exhausted, then a
fresh cycle starts. The folder layout under `Wallpapers/` is curation only; keep
images within two levels of it. A failed or empty listing skips the transfer, so
a dropped mount can never erase the cache, and rotation still runs from the
cached set; the unit status or agent log records the failure. Rotation state is
`~/.cache/wallpapers/state/queue-<Bucket>`; deleting it just starts a new cycle.

On smorespro the first run happens when `graphical-session.target` starts
(login) and every 3 h after that. Nothing to provision: the local PIV agent, warmed
from the login session's PIN cache, authenticates the rsync, and the timer
never opens a dialog (`YK_ENSURE_NO_PROMPT`), so a cold cache fails that run
instead of prompting.

smoreswork runs it from a LaunchAgent with `YK_ENSURE_NO_PROMPT`, the same as
Linux: it reuses the login session's PIN cache and fails closed while the cache
is cold. Two operator steps are needed once.

1. Approve the Automation prompt ("… wants to control System Events") the
   first time the agent sets a wallpaper. Until then the run fails and leaves
   the current wallpaper; it retries on the next interval.

2. Make sure `ssh smortress true` has succeeded once, so the host key is in
   `~/.ssh/known_hosts`: the job sets `StrictHostKeyChecking=yes`.

Verify from a terminal (prompts for the PIN if this session has none cached) or
kick the agent:

```sh
wallpapers sync
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.wallpapers
tail -n 20 ~/Library/Logs/wallpapers.log
```

## Providers

Tofu providers come from `tofu/versions.tf`; notification policies come from
`tofu/main.tf`.

### cloudflare

<!-- manual-step: provider/cloudflare -->

The only OpenTofu provider. The zone `sammohr.dev` already lives in the account;
OpenTofu manages a wildcard proxied CNAME, the `ssh`/`llm`/`memory`/`chat`/
`agent` Access applications, the email allow-list and service-auth policies, and
the tunnel-health and service-token-expiry notifications.

Manual, one-time (dashboard):

- Create the tunnel and store its credentials (see
  `cloudflared-credentials`).
- Mint the Access service token(s) used by unattended clients; the service-auth
  policy references them. OpenTofu does not create tokens. One
  `any_valid_service_token` policy covers `ssh`, `llm`, `memory`, and `chat`, so
  any service token in the account reaches all four endpoints.
- Add **Passkeys** under Integrations → Identity providers and turn on
  *Automatically prompt on the login page*. Enroll once from any application:
  *Sign in with a passkey* → *Set one up* → verify with the email OTP →
  biometric. Passkeys live in the device's authenticator (Google Password
  Manager on Android, iCloud Keychain on macOS); enable that sync if every
  device should share one.
- Set the global session duration (Access controls → Access settings) to one
  month, matching the applications' `720h` (the Access maximum). The email
  allow-list policy stays untouched, so One-time PIN remains the fallback login
  method; a passkey authenticates, and the policy still authorizes.
- Onboard the Email Service sending subdomain (`send.sammohr.dev`) and add its
  SPF/DKIM/DMARC records. Verify the destination (`sam@sammohr.dev`). Leave the
  apex DMARC record alone (`p=reject`).
- Import any existing DNS record, Access application, or policy you want to
  keep before the first apply.
- The personal-site Worker and the `keyboards.sammohr.dev` redirect are
  dashboard objects, not OpenTofu.

Every change: `sudo nix run .#cloudflare-plan`, review the plan, then
`sudo nix run .#cloudflare-apply`. State is root-only in
`/var/lib/cloudflare-tofu` and is **not** backed up: it is outside restic's one
source path (`/var/lib/data`). Losing it costs the import work, not the objects — a fresh state can be
rebuilt by importing the live account (see above), and nothing regenerates it
from the repo. `prevent_destroy` guards the applications and policies; remove it
deliberately if you mean to delete them.

## Backup (restic)

restic is the driver: [`modules/nixos/restic-backup.nix`](../modules/nixos/restic-backup.nix)
defines two repos that hold the same snapshots from one source path,
`/var/lib/data`. The operator guide is
[`modules/features/backup/README.md`](../modules/features/backup/README.md).

| Repo | Target |
| --- | --- |
| `r2` | `s3:https://<account>.r2.cloudflarestorage.com/restic-backup` |
| `local` | `/var/backup/restic`, on the encrypted backup disk |

Nightly at 03:30 with up to 15 minutes of delay,
`--keep-daily 14 --keep-weekly 8 --keep-monthly 12`, and `restic check` after
every run. Only the `r2` repo passes `initialize = true` (a fresh bucket is
expected); the `local` repo is created once by hand, so an empty-but-mounted
`/var/backup` fails the first run and mails instead of quietly starting a new
repo. Both units start `cloudflare-email@%n.service` on failure. The
password is the `restic-password` secret (same for both repos); the R2
credentials come from the sops-rendered `restic-r2.env`.

Before each run, `restic-db-dump` writes `/var/lib/data/db/immich.dump` as
`postgres` (`pg_dump -Fc --no-owner`, temp file then rename). The Immich database
is the photo library's source of truth, so the dump has to be inside the tree;
both repo units `wants` it, so a database that is down delays no backup and the
dump unit mails its own failure.

The NixOS module installs one wrapper per repo with the repository, password
file and credentials already set:

```sh
sudo restic-r2 snapshots        # or restic-local
sudo restic-r2 stats latest
sudo journalctl -u restic-backups-r2 -n 100
systemctl list-timers 'restic-*'
sudo systemctl start restic-backups-local.service   # a manual run
```

### Restore drill

Run this against both repos after changing the backup path and after seeding a
new repo. It proves a snapshot is readable and its data intact without
restoring everything.

```sh
# 1. Pick a file in the live tree and note its hash.
file=/var/lib/data/wallpapers/<file>
sha256sum "$file"

# 2. Restore the wallpapers subtree from the latest snapshot of each repo.
sudo restic-r2 restore latest --target /var/tmp/restore-r2 \
  --include /var/lib/data/wallpapers
sudo restic-local restore latest --target /var/tmp/restore-local \
  --include /var/lib/data/wallpapers

# 3. Each restored copy must hash identically to the live file.
sha256sum /var/tmp/restore-r2/var/lib/data/wallpapers/<file>
sha256sum /var/tmp/restore-local/var/lib/data/wallpapers/<file>

# 4. Read a 2% sample of every pack: the bit-rot check.
sudo restic-r2 check --read-data-subset=2%
sudo restic-local check --read-data-subset=2%

rm -rf /var/tmp/restore-r2 /var/tmp/restore-local
```

Restoring the Immich database from the same snapshot:

```sh
sudo restic-r2 restore latest --target /var/tmp/db-restore \
  --include /var/lib/data/db/immich.dump
sudo -u postgres createdb immich_restore
sudo -u postgres pg_restore --no-owner -d immich_restore \
  /var/tmp/db-restore/var/lib/data/db/immich.dump
```

### Encrypted backup disk

`/var/backup` on smortress is the 4.5T HDD (`ata-ST5000LM000-2AN170_WCJ42WX0`),
LUKS-encrypted: opened at boot from `/etc/crypttab` with a root-only keyfile on
the encrypted root (so boot stays unattended), with a passphrase slot as the
recovery path if the root is lost. The option is `backup.luks` in
[`modules/nixos/backup.nix`](../modules/nixos/backup.nix); smortress enables it
in `modules/hosts/smortress/default.nix` with `backup.device =
"/dev/mapper/backup"`.

The local repo is derived from `/var/lib/data`, so reformatting loses nothing
the R2 repo and the live tree do not hold. Formatting destroys the disk:

```sh
# 1. Prove the offsite repo first: snapshots exist and a sample reads clean.
sudo restic-r2 snapshots | head
sudo restic-r2 check --read-data-subset=2%

# 2. Stop the timers and unmount.
sudo systemctl stop restic-backups-r2.timer restic-backups-local.timer
sudo umount /var/backup

# 3. Keyfile (kept on the encrypted root) + a passphrase slot for recovery.
sudo install -d -m 0700 /etc/luks
sudo sh -c 'head -c 64 /dev/urandom > /etc/luks/backup.key && chmod 0400 /etc/luks/backup.key'
sudo cryptsetup luksFormat --label backup-luks /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ42WX0
sudo cryptsetup luksAddKey /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ42WX0 /etc/luks/backup.key
sudo cryptsetup luksDump /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ42WX0  # 2 keyslots
sudo cryptsetup open --key-file /etc/luks/backup.key \
  /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ42WX0 backup
sudo mkfs.ext4 -L backup /dev/mapper/backup
sudo mount /dev/mapper/backup /var/backup
```

Rebuild and reboot: `/etc/crypttab` opens the disk before the mount, `nofail`
keeps a missing keyfile from blocking boot, and the local unit
(`RequiresMountsFor`) fails loudly instead of writing to the root filesystem.
Create the local repo by hand (the module never initialises it, so a wrong or
empty disk fails and alerts instead of becoming a new repo), then seed it:

```sh
lsblk -f /var/backup          # the encrypted disk, mounted, empty
sudo restic-local init
sudo systemctl start restic-backups-local.service
sudo restic-local snapshots
```

## Syncthing and the vault

Personal files live in one plaintext tree, `/var/lib/data/vault`, owned by the
`vault` user (uid 981) and synced between the hosts in
[`modules/syncthing-devices.nix`](../modules/syncthing-devices.nix). Syncthing
runs as `vault` from the system service in
[`modules/nixos/vault-sync.nix`](../modules/nixos/vault-sync.nix), so the human's
uid has no access to the tree at rest. Nothing is encrypted on disk beyond LUKS:
restic encrypts the offsite copy, which is why the restic password alone
recovers everything.

Device IDs are public keys, so they are committed; each device's `key.pem` is the
only secret. Every NixOS host sets `vaultSync.device` in its `default.nix`,
naming its row in that table.

Pairing a device:

1. Install Syncthing. Android: the `researchxxl/syncthing-android` fork from
   F-Droid/Obtainium, and grant the battery-optimisation exemption — without it
   the folder stops syncing once the screen is off.
2. Read the device ID: `syncthing device-id` on a Linux host, the app's settings
   screen on Android.
3. Add it to the table, set `vaultSync.device` on the new host, and rebuild.
   `overrideDevices`/`overrideFolders` are on, so the table and the folder are
   the whole truth and a click in the UI does not survive the next activation.

Opening the vault:

```sh
v                   # yazi as `vault`, in /var/lib/data/vault
v yazi .            # the same, with a tool named explicitly
v bash              # a shell as `vault`, with the store as the working directory
```

`v` expands to `/run/wrappers/bin/sudo -H -u vault
/run/current-system/sw/bin/vault`. That wrapper enters the store and execs the
command as `vault` with `PATH` limited to the system profile (yazi is installed
there as the no-argument default). Home-manager binaries are deliberately
unreachable: the vault user cannot traverse the owner's 0700 home, and a
user-owned `PATH` entry would let an unattended session plant the tool that runs
as `vault`. Nothing is mounted and no uid is mapped, so every path the tool
opens carries the store's real permissions and no view of the tree outlives the
process. On the NixOS hosts root means the YubiKey touch. `-H` keeps tool config
and state in vault's own home, which the owner cannot read. On the work Mac `v`
runs the same command over SSH on smortress. Nothing is reachable between
sessions.

**Version history** is Syncthing staggered versioning at
`/var/lib/syncthing-versions/vault` on smortress — outside `/var/lib/data`, so
restic never carries it. Restore by copying the versioned file back (strip the
`~YYYYMMDD-HHMMSS` suffix) and letting it converge. A `*.sync-conflict-*` file is
the expected outcome of a two-device edit; keep the newest and delete the rest.

### Vault migration, Cryptomator to plaintext

Do this with Syncthing stopped on every device, and do not rebuild before step 6:
the new service refuses to start until `/var/lib/vault-migrated` exists, and
`tmpfiles` would hand the ciphertext to the `vault` user before it is converted.

1. Snapshot the ciphertext so the old tree stays in the repository:
   `sudo systemctl start restic-backups-r2.service`.
2. Stop Syncthing everywhere (`systemctl --user stop syncthing` before the switch
   removes the user unit, `sudo systemctl stop syncthing` after it) and pause the
   folder on the phone.
3. On smortress, mount the old vault and copy the plaintext out of it:
   `sudo mkdir -p /mnt/oldvault && cryptomator-cli unlock
   --mounter=org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider
   --mountPoint=/mnt/oldvault /var/lib/data/vault`, then
   `sudo mkdir -p /var/lib/data/staging && sudo cp -a /mnt/oldvault/. /var/lib/data/staging/`.
   The decrypted root is the content root; there is no extra `Sync` level inside it.
4. Verify while it is still mounted: `sudo diff -r /mnt/oldvault /var/lib/data/staging`
   must print nothing. Stop here if it prints anything: the next step moves the only
   copy of the ciphertext aside, and an empty store would sync its deletions out.
5. Before swapping, prove the staging tree holds no Cryptomator scaffolding
   (`sudo test ! -e /var/lib/data/staging/d -a ! -e /var/lib/data/staging/masterkey.cryptomator`)
   and no ciphertext (`sudo find /var/lib/data/staging -name "*.c9r" | head` must print nothing).
   Then swap, using `mv -T` so a re-run cannot nest one tree inside the other:
   `sudo mv -T /var/lib/data/vault /var/lib/vault-ciphertext`,
   `sudo mv -T /var/lib/data/staging /var/lib/data/vault`,
   `sudo chown -R vault:vault /var/lib/data/vault /var/lib/syncthing-versions`
   and `sudo chmod 700 /var/lib/data/vault` (copying preserves the old 755 root).
6. `sudo touch /var/lib/vault-migrated`, rebuild, `sudo systemctl start syncthing`,
   and check the folder and its devices in the UI. Do this on every host that runs
   Syncthing: a host whose store will be pulled from the others needs only the empty
   directory, but without the marker its unit is skipped with `unmet condition check
   ConditionPathExists=/var/lib/vault-migrated` and it never joins.
7. Before Syncthing starts on any host that still has ciphertext under `~/Sync`, move
   it aside (`mv ~/Sync ~/Sync.old`) so the guest view cannot see it; delete it when
   the cold copy goes.
8. Rebuild the blob (`deno task blob`; the sentinel check now reads a plain file),
   then `deno task blob --check-only`.
9. Delete `/var/lib/vault-ciphertext` after two restic runs and one page restore.

## Agent VMs

Agents run inside a VM on every host, so nothing they do can reach the host's
sudo, polkit, YubiKey, PIN or admin prompts. T9 changes the default: `a` runs
`maki` on personal hosts and plain `claude` on smoreswork, with no sandbox.
`agent-sandbox maki` / `agent-sandbox claude` remain available (and `ms` uses
the sandbox) only while `kanbeiSplit.cutover.enable` is false; the cutover
removes the sandbox entirely. The design, the accepted residuals and the
retirement table are on smores56/sdlc#427 and `docs/kanbei-split.md`.

Each guest sees an explicit allowlist, not the whole home. `agentVm.allow` and
`agentVm.allowRw` (`modules/nixos/agent-vm.nix`) and the arrays in
`modules/features/agent-vm/default.nix` on the Mac name every visible path;
anything else has no path in the guest at all. On Linux the writable trees are
`~/repos`, `~/wip`, `~/.local/state/maki` and `~/.local/logs/maki`; the
read-only roots are `~/.agents`, `~/.config/maki`, `~/.config/git`,
`~/.local/bin`. On the Mac the writable trees are
`~/Blitzy`, `~/repos`, `~/wip` and Claude's session-state dirs. The writable
trees include repos, and the agent may write their `.git/config` and hooks,
which you later run on the host; that is accepted (full git for agents).
Keep secrets out of the allowlisted trees: run `secret-sweep` after adding
files under the home and move or delete what it reports.

`~/dev` is now `~/wip`. On each host, `mv ~/dev ~/wip` before rebuilding; a
git worktree registered under `~/dev` is recreated with `worktrees prune` then
`worktrees new`.


### Linux (smortress, smorespro)

A microvm.nix NixOS guest that starts at boot (`microvm@agent.service`).
`agent-vm-prep` assembles the guest's home view on a tmpfs before each start,
and virtiofsd writes every guest file as you (guest root included), so guest
root cannot plant root-owned, setuid-root or device files on the host. Credentials are not handed into the guest. Each one is a **capability**
(`agentVm.capabilities`): a host systemd unit holds the sops value in a
systemd credential and exposes a loopback broker; the guest keeps a stable
loopback port, gets a dummy client value where a tool insists on one, and
reads `/run/agent-vm/capabilities.json`/`.env` for the addresses. The
capabilities are Neuralwatt (streaming), TinyFish, Calibre (basic auth),
the memory MCP token, and (on smorespro) the smortress SSH relay; only the
GitHub PAT and the commit-signing key still travel in `agentVm.secrets`.
Every HTTP capability must declare a non-empty `allow` list; an empty list is
rejected. Rotating any mediated secret is: edit the sops entry,
`sudo systemctl restart agent-broker-<name>` on the host. The guest and its
sessions are untouched. `agent-vm-verify` asserts the home view, the shares,
the hand-in secrets and the tap firewall.

The guest closure and the active userland can lag the host. `agent-sandbox
status` (`just agent-vm-status`) prints the booted, current and expected
closures and the number of human sessions. `agent-vm-update` (`just
agent-vm-update`, as root) switches userland in place when only packages or
units changed, and for a kernel/early-boot change reboots the guest after
waiting for human ptys (or with `--force`); the writable store layer is
recreated on that restart. A timer logs drift every 15 minutes.

An allowlist addition applies to a running guest on the next switch (the
activation reconcile adds new binds; removals wait for the next VM start).

Network: tap `vm-agent` (host `10.77.0.1`, guest `10.77.0.2`). The guest
reaches the internet through NAT and, on the host, only the LLM port and its
capability brokers, through socket proxies; it cannot reach other host
services or the LAN.
In the other direction the host reaches only the assistant port on the tap,
through the `agent-vm-ingress` relays (see [smortress/agent](#smortressagent)).

After a host switch, the guest keeps running its old config; running sessions
survive. Pick up guest changes or new top-level home entries with:

```sh
sudo systemctl restart microvm@agent.service
```

`agent-vm-verify` (also `just agent-vm-verify`, which adds sudo) asserts the
boundary from the host after prep, where a compromised guest cannot lie about it:
the view is a read-only `nosuid,nodev` tmpfs, the visible tree is exactly the allowlist,
writable and read-only roots behave, every bind is `nosuid,nodev`, secret files
are 0400 and user-owned, the host holds no `nix-store.img` mount or loop
device, and the tap and firewall chains exist. It is also a oneshot that runs
after every prep, so a regression shows up in `journalctl -u agent-vm-verify`.
`agent-vm-check` (also `just agent-vm-check`) stays the functional smoke test
from inside the guest: allowlisted paths present, everything else absent,
config read-only, state and repos writable, hand-in secrets readable, guest
files owned by you, `mknod` refused, host sshd unreachable, the memory proxy
reachable.

maki reads the real `~/.config/maki` and `~/.config/git` read-only and keeps
its sessions in `~/.local/state/maki` and logs in `~/.local/logs/maki`, both
shared with the host, so the host's unsandboxed `maki` and the guest resume
each other's sessions and `ms` works through `agent-sandbox`. The guest's own
cache, data and gh state live under `/var/lib/agent-vm`. maki is installed
manually in `~/.local/bin` and is shared read-only. One-time migration from
the old launcher state:

```sh
mv ~/.local/state/agent/state/maki/. ~/.local/state/maki/
rm -rf ~/.local/state/agent ~/.local/share/agent ~/.cache/agent
```

The guest's writable store layer is recreated on every start, so guest builds
reset; the host store is never mounted or parsed.

The guest home is read-only apart from the allowlist, so `nix profile install`
cannot write `~/.nix-profile`; use `nix build`, `nix develop`, or `nix shell`
inside a checkout instead.

The personal sops signing key logs in to smortress only through a forced
`agent-ssh` command, which lands in smortress's own guest, never a host shell.
A laptop guest reaches smortress that way through the tunnel.

### smoreswork

A headless Tart macOS guest (`modules/features/agent-vm`). The work Mac is a
standard user: `sudo` asks for the smartcard PIN and then fails at `sam is not
in the sudoers file`; do not use it. `home-manager switch` and user Nix builds
work. `nix upgrade-nix`, daemon changes, admin-requiring Brew casks, and
`sc_auth pair`/`unpair` need IT. Only YubiKey k2 is paired; ask IT to pair or
replace the others. The vault is remote-only: `v` runs
`ssh -t smortress /run/wrappers/bin/sudo -H -u vault /run/current-system/sw/bin/vault yazi`
(the NixOS hosts run local `v [tool]`). Use
`key-backup --no-host-key` on this Mac; the default host-key read needs root.
Removing the retired root Syncthing daemon and `/var/lib/data/vault` is an IT
action (`launchctl` system domain), after confirming smortress has the data.

Once per Mac:

1. Turn off AirPlay Receiver (System Settings → General → AirDrop & Handoff):
   it is the one host service the guest can reach that can pop a dialog.
2. Narrow Docker Desktop's File sharing (Settings → Resources → File sharing)
   to the agent-safe trees: `~/Blitzy`, `~/repos`, `~/wip`. Never `$HOME`,
   `~/.config`, `~/.cache`, `~/Library`, `~/Documents`, `~/Downloads`,
   `~/Desktop`, `~/Vault`, or `~/Sync`: a container can read everything in the
   listed trees.
3. Run `agent-sandbox provision` (clones the pinned image, hardens the guest,
   rotates its admin password, installs the login key), then `a` and sign in to
   Claude inside the guest; the guest keeps its own login.

`agent-sandbox restart` stops the VM so the next launch re-plans the shares;
`agent-sandbox stop` shuts it down. The guest sees only `~/Blitzy`, `~/repos`,
`~/wip`, and Claude's `projects`, `file-history`, `tasks`, and `plans`
directories, so `claude --resume` sees host and guest sessions alike. Claude's
config and `~/.claude.json` stay host-only; the guest keeps its own login and
config, and does not read the host's `history.jsonl`. The
`github-{personal,work}-{pat,signing-key}` secrets are handed in as files on
each launch; the rest stay on the host. The guest gets
guest-local copies of gh, gcloud, git, and kube config, with `GH_CONFIG_DIR`,
`GIT_CONFIG_GLOBAL`, `KUBECONFIG`, and `CLOUDSDK_CONFIG` pointed at the copies,
Docker comes from the host's Docker Desktop
through a per-session forwarded socket, so Docker Desktop must be running.

#### Guest-local Nix store (opt-in)

When you need to build or validate Darwin outputs inside the guest, run once:

```sh
agent-sandbox provision-nix
```

It boots the guest without the host store, removes the launcher's synthetic
`/nix` entry, reboots, installs Determinate Nix into the guest's own APFS
volume, installs git/gh/jq/docker-client/ripgrep/claude-code/cacert/gcloud/kubectl
into the guest profile, sets `min-free`/`max-free` and a weekly GC, and writes
the `guest-nix` marker. Later launches use the guest profile and store, so the
agent can run `nix flake check`, `nix build`, `nix develop`, and `nix shell`
without forwarding the host nix-daemon. The guest store is separate and is
GC'd; the host store is not mounted in this mode, so the guest substitutes from
`cache.nixos.org`.

Sign in to Claude inside the guest; the guest keeps its own login and
`~/.claude` config. The host binary is not used in this mode. Do not re-run
`agent-sandbox provision` after this. To return to the
shared host store, delete `~/Library/Application Support/agent-vm/guest-nix`;
the guest store is shadowed, not deleted. Validate this path on the Mac before
relying on it for a release. If provisioning fails, a fresh guest is the reliable
reset (`tart delete agent-vm`, then `agent-sandbox provision`); re-running may
not repair a partial install.

### Scrub at source

`secret-sweep` (offline, redacted gitleaks) scans the home, skipping `~/Library`
on the Mac. Run it on each host, then delete or move each finding out of the
shared paths. Credentials that were only ever needed by humans are better
revoked than hidden: the two work GCP service-account keys
(`dev-service-account@blitzy-os-dev`, `@blitzy-platform-stage`) were removed
locally; revoke them in IAM only after confirming with the team that nothing
else (CI, teammates) uses them.

### todo.txt

`/var/lib/data/todo/todo.txt` is the single list. The tree is its own
size-capped filesystem: `/var/lib/todo.img` is a 256 MiB ext4 image (the file is
created by tmpfiles, formatted by `todo-image.service`), mounted at
`/var/lib/data/todo` by `var-lib-data-todo.mount` and owned `vault:vault` 0700.
The cap bounds a runaway capture, and the mount hides the empty plain directory
an unmounted image leaves behind. Syncthing and `td` both require it: the daemon
carries `RequiresMountsFor=/var/lib/data/todo`, and `todo-open` refuses to start
when `mountpoint -q /var/lib/data/todo` fails.

The vault Syncthing daemon — the same daemon and device identity as the vault,
there is no separate todo daemon — syncs the `todo` folder from that path on both
hosts, and the daemon GUI at `http://127.0.0.1:8384` shows both folders. The
folder starts only after the vault migration marker `/var/lib/vault-migrated`
exists.

`td` opens the list as `vault`:
`/run/wrappers/bin/sudo -u vault /run/current-system/sw/bin/todo-open`. One
YubiKey touch opens the list and no process of the owner writes it; a `sudo`
planted on `PATH` never receives the touch. `todo-open` refuses when the tree is
not mounted, or when `todo.txt`, `done.txt` or `inbox.txt` is a symlink (tuxedo
would follow it, so the vault user's write could land outside the store), then
execs tuxedo. Both paths are absolute, so the caller's `PATH` cannot supply
either binary.

tuxedo's config is `/var/lib/syncthing/.config/tuxedo/config.toml`, owned
`vault` and reinstalled on every activation (`theme = Terminal`); its cache is
`/var/lib/syncthing/.cache`. Both live in vault's home, outside the synced tree.

The common module is [`modules/features/todo.nix`](../modules/features/todo.nix);
the filesystem, Syncthing folder and `todo-open` wrapper are
[`modules/nixos/todo-daemon.nix`](../modules/nixos/todo-daemon.nix), imported by
both hosts.

First activation on a host that still has a plain todo directory:

1. Stop the daemon so the seeding copy is not racing a sync:
   `sudo systemctl stop syncthing`.
2. Rebuild (`just switch smortress`; on smorespro:
   `home-manager switch --flake .#smores@smorespro` then
   `sudo nixos-rebuild switch --flake .#smorespro`). Starting the mount runs
   `todo-image.service`, which formats the image and copies the current plain
   `/var/lib/data/todo` in, so the mount never hides the only copy of the tree.
3. `sudo systemctl start syncthing`, then check the folder in the UI. With
   `kanbeiVm.enable` on, `/mnt/kanbei/todo` in the guest must show the same list.

The old plain directory still sits underneath the mount. After a restic run and
a page restore have proven the image, move the shadow aside (it is vault-owned
0700 and never synced):

```sh
sudo systemctl stop syncthing
sudo systemctl stop var-lib-data-todo.mount
sudo findmnt --mountpoint /var/lib/data/todo    # must print nothing
sudo mv /var/lib/data/todo /var/lib/data/todo.old
sudo systemctl start var-lib-data-todo.mount
sudo systemctl start syncthing
```

Delete `/var/lib/data/todo.old` after those checks.

`~/Tasks/todo.txt` on smorespro is retired: nothing in the configuration creates
or links it. If an old copy, or the old `~/.local/share/todo` tree, is still
there, move it into `/var/lib/data/todo` before step 2 and then delete the
leftovers (`rm -rf ~/Tasks ~/.local/share/todo ~/.local/state/syncthing-todo`).

The phone reuses the existing `smorespro` vault device (`HYVRSZX-...`) for the
`Todo` folder; the old `FADK72N`/`smorespro-todo` device is retired. Remove it
from Syncthing-Fork and let the `Todo` folder sync from the existing
`smorespro` and `smortress` devices. Keep the folder outside the vault folder.

Edit on one device at a time. A concurrent edit leaves
`todo.sync-conflict-<date>-<time>-<device>.txt`; 0x54ask merges it, or merge by
hand from the 30-day version set under `/var/lib/syncthing-versions/todo`.

The work Mac is out of scope.

The loop mount is exercised on the first real switch, not in CI (the repo has no
NixOS VM test for it). To test the pieces on a scratch host:

```sh
truncate -s 256M /tmp/todo-test.img
mkfs.ext4 -q -F -L todo-test /tmp/todo-test.img
sudo mkdir -p /tmp/todo-test
sudo mount -o loop,noatime,nosuid,nodev /tmp/todo-test.img /tmp/todo-test
sudo chown vault:vault /tmp/todo-test && sudo chmod 0700 /tmp/todo-test
sudo umount /tmp/todo-test
```

## Public services

Services come from `webProxy.services` on each NixOS host. Each becomes
`<name>.<domain>` through the tunnel. `ssh`, `llm`, `memory`, `chat`, and
`agent` have Cloudflare Access applications (hand-written in `tofu/`);
`access.enable` on any other service fails evaluation. The data apps are served
by the cluster — `photos.sammohr.dev`, `music.sammohr.dev`,
`opds.sammohr.dev` — with their own app auth and the zone rate limit.

### Books (OPDShelf, in the cluster)

Neither this host nor the tunnel serves the library: OPDShelf runs in the
`calibre` namespace over the same `/var/lib/data/books` share, and
`opds.sammohr.dev` is its hostname (`docs/data-migration.md` in
`smores56/homelabs-platform`). OPDS clients and the web panel authenticate as
`smores56`; the password is the cluster Secret `opdshelf-admin-password-sops`,
created from `~/secrets/homelabs-platform/opdshelf-admin-password.yaml`.

Agents never talk to the server. `fanficfare-download` writes the EPUB to
`~/wip/books`, and `books-shelf.service` (`modules/hosts/smortress/books-shelf.nix`)
copies finished files into `imported/` inside the library share. The folder is
the catalog, so nothing else runs. Drop a file in by hand the same way.

### smortress/immich

`photos.sammohr.dev` is served by the cluster since the cutover; this host
service's own tunnel route is retired, so only the LAN URL below reaches it.
The cluster app is public (no Access) and protected by Immich's own login; the
first user to register becomes the admin, so register it immediately after the
first start — anyone who reaches the instance first takes the account. Phones
also use the LAN URL
`http://<lan-ip>:2283` (`immich.lanSources`) because Cloudflare caps a single
upload at 100 MB and Immich neither chunks nor resumes. Configure both URLs in
the mobile app.

### smortress/llm

<!-- manual-step: service/smortress/llm -->

`llm.sammohr.dev`, TCP to llama.cpp, with the service-auth policy so maki can
call it unattended. `api_key = "none"`; the tunnel and Access are the boundary.

### smortress/memory

<!-- manual-step: service/smortress/memory -->

`memory.sammohr.dev` is TCP to the loopback memory wrapper (`ports.memoryMcp`),
behind the same service-auth policy as `llm`. The wrapper validates the scope
headers the Maki shim sends (group, cwd, actor, machine), refuses work groups,
enforces a 60 s deadline per tool call, and is the only tunnel target. Searches
read every allowed project plus `global` and label each result with its group
and `actor@machine`; writes stay in the cwd-derived group. It owns the typed
registry (`/var/lib/memory/registry.sqlite`, schema version in `PRAGMA
user_version`; v2 migrates to v3 in place, any other version is refused) and
verifies queued writes against FalkorDB. Raw
Graphiti runs on an internal loopback port (`modules/nixos/memory.nix`) and is
never tunneled. The module adds the operator to the `memory` group, which
applies after `just switch smortress` and a fresh login (or `newgrp memory`).

FalkorDB and Graphiti run as rootless podman containers under the `memory` user
(uid 982). The image store under `/var/lib/memory/.local/share/containers` is
not backed up. Check with `ss -ltnp 'sport = :6379'` (must be 127.0.0.1) and
`sudo -u memory XDG_RUNTIME_DIR=/run/user/982 podman ps`.

**Extraction gateway.** Graphiti extracts through `memory-llm-proxy` on
`127.0.0.1:8082`, the single egress to Neuralwatt. It reads `neuralwatt-api-key`
through a systemd credential, adds the bearer header and
`reasoning_effort: "none"` (a reasoning model otherwise spends its token budget
thinking and returns empty content), always replaces the caller's
`Authorization`, forwards only `POST /v1/chat/completions`, `POST /v1/embeddings`
and `GET /v1/models` (bodies over 10 MB get 413), holds a concurrency permit per
extraction request (embeddings and the model list run in their own lane), and
retries 429/503 up to `MEMORY_UPSTREAM_RETRIES`, honouring a
numeric `Retry-After`. Rotating the key is a sops
edit plus rebuild; the secret's `restartUnits` restarts the gateway.

- A missing or empty credential keeps the gateway from starting, which also
  fails the wrapper's `preStart`. `/health` only proves the process is alive:
  probe `/v1/models` for upstream access.
- The listener is loopback-only and unauthenticated, so the host's user
  boundary is the billing boundary.
- The tier allows three concurrent upstream slots: two for memory
  (`MEMORY_UPSTREAM_CONCURRENCY=2`, matching Graphiti's `SEMAPHORE_LIMIT=2`) and
  one for Maki. If 429s reappear, lower both before anything else.
- A gateway outage does not fail a write: Graphiti answers 200 and extracts from
  an in-memory queue, so the registry row stays `pending` with no graph episode
  (`journalctl -u memory-graphiti-mcp`). The reconciler replays it after
  `MEMORY_RECONCILE_GRACE` (3 h, restarted at every attempt, so a row fails only
  after three windows; long enough that a draining backlog is not resubmitted as
  duplicates); to test, set it to `300` in a drop-in under
  `/run/systemd/system/memory-mcp.service.d/`, `daemon-reload`, restart.

**Embedder.** Graphiti embeds with `qwen3-embedding-8b` (4096-d) through the same
gateway. Changing the model changes the vector width, so wipe the graph and
replay it (see *Rebuilding the graph*).

**Clients.** Personal hosts run `cloudflared-memory`, which forwards loopback
`ports.memoryMcp` with the Access service token. Maki's `~/.config/maki/mcp.toml`
starts `memory-mcp-shim` (server `graphiti`; Maki's built-in memory plugin is
off), which derives the project group from Maki's cwd once at start and sends
the hostname as `X-Memory-Machine`: restart Maki after changing directories or
`mcp.toml` (`/cd` does not restart stdio children). The same package installs
the `memory` CLI.

**Backup.** The registry is the system of record and the graph a derived index.
`memory-export.timer` runs `memory-export.service` daily (00:00 plus up to an
hour of delay, as root) and overwrites three files in
`/var/lib/data/memory-export/` (0700): `registry.sqlite` (SQLite online
backup), `episodes.jsonl` (content and provenance) and, when `BGSAVE`
finishes, `graph.rdb`. A failed graph snapshot removes the previous
`graph.rdb` (it would not match the new registry) and makes the run exit
non-zero without invalidating the registry copy. The directory is inside
restic's source tree, which owns history and integrity. Run one now with
`just memory-export`; inspect with `journalctl -u memory-export.service`.

**Restore.** `sudo memory restore <export-dir>` (or `just memory-restore <dir>`),
where the directory holds a restic-restored or live export:

1. checks that `registry.sqlite` opens and its schema is the current one or the
   previous version (the staged copy migrates on install), refusing any other;
2. stops `memory-mcp`, `memory-graphiti-mcp`, `memory-llm-proxy` and
   `memory-falkordb` (a running FalkorDB would rewrite its AOF);
3. parks the live registry as `registry.sqlite.pre-restore-<timestamp>` and
   installs the export's with an atomic rename, fixing ownership first so a
   failed `chown` leaves the old registry in place;
4. restores `graph.rdb` when present: the old `appendonlydir` is renamed to
   `appendonlydir.pre-restore-<timestamp>` and FalkorDB restarts. Otherwise the
   registry is restored alone.

Delete the `*.pre-restore-*` files once `GRAPH.LIST` and a search confirm the
result. Flags: `--dry-run` verifies and prints the plan; `--no-stop` is accepted
only with `--dry-run`; `--start` starts the services afterwards; `--owner
user:group` (default `memory:memory`, empty skips). A restore holds
`<state>/.restore-in-progress` and `memory export` refuses to run while it
exists; a failed restore leaves it, so remove it after reconciling.
`tests/memory_export_restore.sh` runs the same procedure against temp
directories.

**A restored graph snapshot needs one start with the AOF off.** Redis with
`appendonly yes` starts empty when no AOF exists; it does not fall back to
`dump.rdb`. Moving the old AOF away is necessary but not sufficient. Start
FalkorDB once with `REDIS_ARGS='--appendonly no --save ""'` on the same image
and data directory, confirm `GRAPH.QUERY <group> "MATCH (n) RETURN count(n)"`
is non-empty, run `redis-cli CONFIG SET appendonly yes` (which rewrites the AOF
from the loaded snapshot), then hand the store back to the unit. In the cluster
the same sequence is the `REDIS_ARGS` patch in `homelabs-platform`'s restore
runbook. Skipping this leaves an empty graph, and only `memory reindex --all`
recovers it.

When the graph snapshot is missing, `just memory-reindex --all`
(`memory reindex`) is the replay path: it requeues active rows with no matching
episode and resubmits a bounded slice immediately; repeat until it reports
nothing left. A group that looks almost entirely missing while its graph is not
empty is refused without `--force`.

**Deploy and verify.** After changing the wrapper, shim, package, gateway or
export unit: `just switch smortress` and `just home-switch smores <host>`. Then
on smortress:

```sh
systemctl status memory-mcp memory-llm-proxy
curl 127.0.0.1:8182/health
curl 127.0.0.1:8082/v1/models        # proxied to Neuralwatt
cd ~/repos/<repo> && memory status    # group, registry counts, readiness
systemctl list-timers 'memory-export*'
```

For a first deployment, apply the Access application before rebuilding so it is
in place when the hostname starts routing:

```sh
sudo nix run .#cloudflare-apply
just switch smortress
```

**One-time cleanup after the memory trim.** A switch leaves this state behind;
delete it by hand once the new export has run and restic holds a snapshot of it:

- the old timestamped export directories under `/var/lib/data/memory-export/`
  (`<timestamp>/`, root only); the new export writes `registry.sqlite`,
  `episodes.jsonl` and `graph.rdb` directly into that directory;
- `/var/lib/memory/index.sqlite` and `/var/lib/memory/internal.token`;
- `/var/lib/private/llama-cpp-embed` and `/var/cache/private/llama-cpp-embed`
  (the removed `llama-cpp-embed` unit's state);
- `~/.local/state/memory/ingest-*.json`, `ingest.log`, `ingest-state.json*` and
  `ingest-all-sessions.json` for the user that ran the ingest.

### Rebuilding the graph

Required after changing the embedding model, and the answer to a lost or
mismatched graph. The registry is untouched; take an export first
(`just memory-export`) anyway.

```sh
just switch smortress     # applies the model change
just memory-rebuild       # stop, wipe falkordb data, start (sudo)
just memory-reindex --all # repeat until it reports nothing left
```

A pass that finds the graph already holding rows an earlier pass requeued is
recognised as the same reindex and is not stopped by the mostly-missing guard;
only a first pass against a graph that matches none of the registry still needs
`--force`.

Do not run it while anything else writes memory.

### smoreswork memory instance

The work Mac runs the same service description as smortress
(`modules/features/ai/memory/service.nix`) under launchd agents
(`modules/features/ai/memory/darwin.nix`, instance in
`modules/hosts/smoreswork/memory.nix`). Nothing leaves the machine except model
calls, and work repos are accepted there (`MEMORY_WORK_POLICY=allow`, from
`user.aiProfile = "work"`); the smortress wrapper pins `refuse`.

- **Containers.** FalkorDB and Graphiti run through `/usr/local/bin/docker`
  (Docker Desktop, socket `~/.docker/run/docker.sock`), published on
  `127.0.0.1` only; Graphiti reaches the proxy and FalkorDB via
  `host.docker.internal`. Docker Desktop must be running; the agents wait for it.
  Container output is in `docker logs memory-graphiti-mcp`; the others log to
  `~/Library/Logs/memory-*.log`.
- **Extraction.** There is no Anthropic key: the proxy answers Graphiti's chat
  completions by running `claude -p --model claude-haiku-5-5` on the Claude
  subscription (tools, MCP servers, settings and session files all off), at most
  four at a time (Graphiti's queue limit follows). Claude must be installed at
  `~/.local/bin/claude` and signed in. A failed or timed-out run is retried up to
  three times before the proxy answers 502/504, and the registry row stays `pending`
  until the reconciler replays it. `curl 127.0.0.1:8082/health` is 503 when the
  binary is missing. Graphiti (`:8184`) and FalkorDB (`:6379`) are unauthenticated and
  reachable by every local user (accepted); the instance serves only work repos,
  `global` and directories outside any repo.
- **Embeddings.** `text-embedding-3-small` (1536-d) through the employer's OpenAI
  key (`openai-api-key`). Changing the model or width re-embeds the corpus: wipe
  `~/.local/share/memory/falkordb` and run `memory reindex --all`.
- **State and export.** Registry and graph live in `~/.local/share/memory`
  (FileVault); the wrapper's bearer token is generated there on first start. The
  `memory-export` agent runs nightly at 03:17 (after wake if the Mac was asleep)
  and keeps the newest seven dated directories in `~/.local/share/memory-export`
  (plus the newest one holding a graph, if recent graph snapshots failed); a non-zero
  exit raises a notification.
  There is no restic and no off-machine copy. `memory restore` drives systemd and
  does not apply here; restoring is stopping the agents and copying a dated
  export's `registry.sqlite` over `~/.local/share/memory/registry.sqlite`.
- **Clients.** `memory` is on `PATH`. Each `home-manager switch` merges the
  `memory` stdio server (`memory-mcp-shim`) into `mcpServers` of `~/.claude.json`
  and sets `autoMemoryEnabled: false` in `~/.claude/settings.json` (see
  `modules/features/ai/claude.nix`); no other key is touched. Restart running
  Claude sessions to load the server.

### smortress/agent

<!-- manual-step: service/smortress/agent -->

Retired by `kanbeiSplit.cutover.enable` (T9). Until the switch flips, the text
below describes the live Open WebUI/Letta pair; on the cluster generation the
unit and its tunnel entry are removed in the follow-up deletion commit.

`agent.sammohr.dev` → the loopback Open WebUI server (`ports.openWebui`), HTTP
behind Access plus Open WebUI's own email/password login. It is the phone PWA
and the desktop web app for the Letta agent; SQLite, uploads and the workspace
live under `/var/lib/data/open-webui`, so restic covers them with the durable
tree.

A blessed device does not see Access at all: its local proxy
(`modules/features/chat-proxy.nix`) adds the device's service token and listens
on `http://127.0.0.1:8787`. Open that URL **on the blessed device itself**; the
listener is loopback-only. Other devices use `https://agent.sammohr.dev` and the
email OTP prompt as before.

**One backend: the Letta App Server.** `modules/nixos/open-webui.nix` declares a
single OpenAI-compatible connection at `http://127.0.0.1:42701/v1`, keyless
(`none`, because Open WebUI rejects an empty key). The App Server runs in the
guest with `--openai-api`, which adds `/v1/models`, `/v1/chat/completions` and
`/v1/responses` to its loopback listener; the host reaches it through the
`agent-vm-ingress-42701` relay, so the App Server has no public hostname and
needs no `--ws-auth`. `ENABLE_PERSISTENT_CONFIG` is off: the connection comes
from the environment and admin-UI edits do not survive a restart.

**Continuity.** `ENABLE_FORWARD_USER_INFO_HEADERS=True` makes Open WebUI send
`X-OpenWebUI-Chat-Id`, and the App Server uses that header as the conversation
key for streaming requests. One Open WebUI chat is therefore one persistent
Letta conversation, and MemFS is shared across all of them. Without the header
every turn would start a fresh temporary conversation and the agent would lose
the thread.

`DEFAULT_MODELS` is `nanobot`, the agent's *name*: the App Server advertises
each agent as a model named after it when that name is unique, and the picker
lists that name. Renaming the agent breaks the default. The agent id also
resolves as a model id, but the picker would not show it.

**The agent runs its own tools.** Open WebUI declares no MCP tool servers, no
code interpreter and no web search: the agent has its own shell, file access,
web search through the `tinyfish` capability and memory through MemFS. Offering
Open WebUI's would either be ignored by the OpenAI-compatible layer or duplicate
what the agent already has.

**Chat is browser-only.** The Access application admits the email allow-list and
a service token; nothing else calls Open WebUI's API.

Apply the edge with `just cloudflare-apply` and `just switch smortress`. The
retired `chat.sammohr.dev` application cannot be destroyed in the same apply
that drops it, because its old block carried `prevent_destroy`: run `just
cloudflare-tofu state rm cloudflare_zero_trust_access_application.chat` first,
then delete the orphaned application in Zero Trust. A host switch does not
restart the guest (`microvm.vms.agent.restartIfChanged = false`), so restart it
once after this change or the guest firewall and relay stay on the old
generation: `sudo systemctl restart microvm@agent.service`. Until the runtime
listens on the port the ingress returns 502. Each blessed device needs a
re-deploy too, because its `chat-proxy` now names the new hostname.

**The App Server itself has no public hostname.** It binds loopback in the
guest; the host relay `agent-vm-ingress-42701.socket` forwards to the guest
relay of the same name, which listens on the tap address and forwards to
`127.0.0.1:42701`. The relays are L4, so the guest also receives Cloudflare's
`Cf-Access-Jwt-Assertion` when a request arrives through the tunnel; treat it as
a human credential there (do not log or forward it) and keep the Access session
short. Any host process can also reach the loopback relay without Access, so
keep the host single-user.

The runtime is `letta-assistant.service` in the guest, running `agent-letta
server` (`letta server --backend local --openai-api --listen
ws://127.0.0.1:42701`, `Restart=always`). The wrapper pins the local backend so agent state cannot
leave the guest, and sets `DISABLE_AUTOUPDATER=1` because the store is
read-only. Its state is `~/.local/state/letta`, which is also the restic path:
`home/` holds the CLI's own `~/.letta` settings, and `backend/` is
`LETTA_LOCAL_BACKEND_DIR` with `memfs/`, `conversations/`, `agents/`,
`providers/` and `runs/`. The backup needs no dump step and no excludes, unlike
nanobot's SQLite sessions: Letta's state is JSONL and git, which the host reads
directly. Nix seeds `backend/providers/auth.json` with an OpenAI-compatible
record pointing at the neuralwatt capability broker
(`http://127.0.0.1:8083/v1`), which injects the real key; the guest-side key is
Letta's own `not-needed` placeholder. Nix owns that file until a `/connect`
rewrites it, after which the edited file wins and removing it re-installs the
Nix record. The unit exists only on smortress; the laptop guest has neither the
service nor the state share.

The Graphiti corpus was migrated before the service was first deployed, into a
staging tree at `~/wip/letta-migration/state` (the guest could not write
`.local/state/letta` until the view was rebuilt). After the first switch and
guest restart, move it into place once:

```sh
mv ~/wip/letta-migration/state/* ~/.local/state/letta/
```

That tree holds the agent record, its MemFS git repository and the provider
record; the service picks it up on the next start. `~/wip/letta-migration` also
keeps `episodes.jsonl` (the raw dump) and `project.py` (the projection script),
which are not needed at runtime.

The move also strands the CLI's own bookkeeping: `home/.letta/settings.json`
and `settings.local.json` record the backend as an absolute
`local:<path>` key, and the migration ran against the staging path. The service
is unaffected (it reads `LETTA_LOCAL_BACKEND_DIR`), but the CLI would look for
the agent in the now-empty staging tree and start a fresh one. Repoint both
files once:

```sh
cd ~/.local/state/letta/home/.letta
sed -i 's#local:/home/smores/wip/letta-migration/state/backend#local:/home/smores/.local/state/letta/backend#g' \
  settings.json settings.local.json
```

Verify with `letta --backend local agents list`: it must return the migrated
agent, not an empty list.

**Neuralwatt subscription.** The account is on Standard monthly: $50 prepaid
per month for 6.25 kWh at $8/kWh, with same-rate overage past the allowance.
Energy billing is the right shape for this workload: 5.45B tokens were mostly
prompt-cache reads, so the last month cost $30.30 in billed energy against
about $124 at nominal token prices. The assistant shares `neuralwatt-api-key`
with Maki, so usage is not separable per client; the account-level monthly
allowance and the overage cap in the Neuralwatt console are the only spend
bound. Set or change the cap there, not in the repo, and keep a payment method
on file so a small overage does not stop the assistant at the prepaid limit.
There is no dedicated assistant key and no new `agentVm.secrets` name.

### smortress/nanobot

<!-- manual-step: service/smortress/nanobot -->

Retired by `kanbeiSplit.cutover.enable` (T9): nanobot runs as the unsandboxed
pod in `homelabs-apps`, not in the host microVM. Until the switch flips, the
text below describes the live guest; the host relay goes with the guest.

`nanobot.sammohr.dev` → the host loopback relay
`agent-vm-ingress-42700.socket`, which forwards to the guest relay of the same
name; the guest relay listens on the tap address and forwards to the runtime on
`127.0.0.1:42700`. Same shape as `agent`: loopback-only runtime, Access as the
remote gate, the runtime's own pairing as the second layer. Apply the edge with
`just cloudflare-apply` and `just switch smortress`, then restart the guest once
(`sudo systemctl restart microvm@agent.service`) so the new relay and firewall
rule take effect.

The runtime is `nanobot-assistant.service` in the guest, running
`agent-assistant gateway` (`nanobot gateway --foreground`, `Restart=always`).
The `serve` subcommand is the interactive WebUI client, not the service. The
unit exists only on smortress; the laptop guest has neither the service nor the
state share. Its instance, sessions, workspace, and generated WebUI token live
under `~/.local/state/agent-assistant`, which is also the restic path. The
backup excludes `logs`, `run`, `media`, `llm_usage.sqlite3`, the live
`sessions.sqlite3` databases and their WAL, the WebUI token, and `gh`; before
each snapshot the host runs `agent-assistant dump` **inside the guest**, which
writes per-workspace copies to `backup/`. Never open the live database from the
host: a host-side process bypasses the guest's WAL locks and breaks the running
gateway (`database disk image is malformed` / `disk I/O error`). Re-pair the
phone and run `gh auth login` after a restore.
`agent-sandbox agent-assistant token` prints the WebUI token; deleting
`home/.nanobot/web-token` and restarting the service rotates it. Nix owns
`config.json` until the WebUI edits it; after that the edited file wins, and
removing it re-installs the Nix config. The assistant uses the `neuralwatt`,
`tinyfish`, and `memory` capabilities; no mediated key is in the guest. The
GitHub PAT and signing key are the #459 residuals. The personal skills are
every `~/.agents/skills` entry except `brain`, linked at start. `agent-sandbox
status` and `sudo agent-vm-update` manage the guest update state.

### Phone file search

`files-mcp` is a read-only file-search MCP on loopback `ports.filesMcp` over
`/home/smores/{repos,Documents,Downloads,dev}`. T9 retires it with Open WebUI:
`kanbeiSplit.cutover.enable` removes the unit, and the follow-up commit deletes
the module and its port. Nothing registers it as a tool connection any more.
While the switch is off it still runs, unregistered, for any MCP client.

Tools: `file_search` (file names and contents), `file_read` (one file, with
line numbers), and `file_list`. Paths outside the roots, secret-like files
(`.env*`, keys, `.ssh`, `.gnupg`), and employer checkouts are refused; the
employer check reuses memory's markers, so `smores.flow=pr` or a `blitzy-*`
remote is enough. `.git`-ignored trees are skipped, which includes unmerged
`.worktrees` checkouts; a file that exists only on an unmerged branch is not
searchable until it is on the checked-out tree.

### smortress/ssh

<!-- manual-step: service/smortress/ssh -->

`ssh.sammohr.dev`, SSH to the loopback sshd (key-first), with service auth for
`cloudflared access ssh`. `ssh` must keep Access enabled; evaluation fails
otherwise.

`smortress` logs in with the PIV keys in slot 9a through the laptop's PIV agent,
which `piv-ensure` (the ProxyCommand) loads on first use and reloads from the
login-session PIN cache after another PIV client reset the card session. The
forwarded agent holds only the touch-only sudo handles.

With no YubiKey attached at all, the client proxy opts into the password
fallback (`YK_ENSURE_PASSWORD_FALLBACK` in `modules/features/cloudflared.nix`):
the pre-connect stands down and ssh falls through to the `smores` account
password, the same one behind `secret/smores-password-hash`, answered in the
Linux session's masked dialog (`modules/features/fido2.nix`; macOS has no
session askpass and prompts on the terminal). It is the account
password, and `sudo` falls back to it, so this login is root-equivalent; the
Cloudflare Access policy plus the loopback bind stay the outer gate. A key
stack that cannot be enumerated (pcscd down, a timeout), a card that is present
but unreadable, a second card (piv-ensure needs exactly one), or a
`YK_ENSURE_NO_PROMPT` caller all keep failing the PIV pre-connect instead of
downgrading, and the PIV-only hosts (tang-pi) never opt in.

### music.sammohr.dev

<!-- manual-step: service/smortress/navidrome -->

Navidrome at `https://music.sammohr.dev/`, public with its own auth and under
the same per-IP rate limit as the other public apps. Create the first account
in the web UI; it becomes the admin.

## Recovery

smortress has no inbound port, so the physical console is the out-of-band path.

**No SSH from a client.** A client needs the Access service token and an SSH
identity. The token is delivered per host by sops
(`/run/secrets/cloudflare-access-ssh-token` on NixOS, the sops-nix user path on
Darwin); a missing or malformed file makes `cloudflared-access` fail closed with
the path in the error. The identity is the YubiKey PIV key in the PIV agent
(`modules/features/piv.nix`). Run `ssh-pub-keys` to write the committed
`~/.ssh/*.pub` and refresh `~/.ssh/allowed_signers` (every `home-manager switch`
and bootstrap also run it). Public keys are literals in
`modules/lib/yubikey-keys.nix`, so a rotation happens there. The work Mac
permits `~/.ssh/google_compute_engine` as the one exception to the
private-key check. Rotating the token is a sops edit (`sops secrets/<host>.yaml`)
plus a switch; the wrapper reads the file on each connection.

**smortress unreachable.** At the console (`<tunnelName>` is
`webProxy.tunnelName`):

```sh
systemctl status cloudflared-tunnel-<tunnelName>
sudo systemctl restart cloudflared-tunnel-<tunnelName>
```

If the host will not boot, reinstall: `nix run .#install -- <hostname> root@<ip>`
(see the `install` app), then run `bootstrap`.

**Cloudflare token invalid or rotated.** The running tunnel keeps serving, but
plan/apply fail. Rotate it (see `cloudflare-api-token`) and check with
`sudo nix run .#cloudflare-plan`.

**Access misconfiguration.** Clearing `access.enable` on `ssh`/`llm`/`memory`/
`chat`/`agent` fails evaluation, and OpenTofu has `prevent_destroy` on those apps and
policies. A wrong *policy* (e.g. email) still locks out the browser: fix it in
OpenTofu, or in the dashboard as break-glass.

**sops cannot decrypt on smortress (host key lost).** Its age recipient derives
from `/etc/ssh/ssh_host_ed25519_key`. From a laptop with the admin identity, add
the replacement host recipient to `.sops.yaml` and run
`sops updatekeys secrets/smortress.yaml`.

**Recovery page (what the family opens).** Create
`/var/lib/data/vault/Documents/sentinel.txt` as `vault`, for example
`v bash -c 'printf "sentinel: 6f1c2a7e\n" > Documents/sentinel.txt'`. Edit on one
device only, let Syncthing settle and let the nightly restic run so the newest
snapshot contains it. Then `nix run .#cloudflare-apply` creates the Pages project,
`recovery.sammohr.dev` and its CNAME (run it twice if the domain is still
pending), and the bucket CORS policy that lets the page read restic from the
browser; without that policy every read fails as "Failed to fetch". The
`CLOUDFLARE_API_TOKEN` repository secret must exist (see
*Cloudflare Pages token* in `docs/key-rotation.md`). In `recovery/`,
`deno task blob` and `deno task blob --check-only` must both pass. Retype the
recovery password at every prompt: the builder asks a third time and opens the
written file with that fresh entry, because a pasted value or a different
Unicode form of an accented character would print a password the page cannot
open. The letters,
drive contents and labels are the operator own template, kept outside this
repository; `recovery/README.md` describes what the page expects of them.

**Admin key or its passphrase lost.** Recovery is a new identity, not a
restore; see *Replace the admin identity* under *Admin age key (keys.age)*.

## Flake apps

Apps come from `modules/flake/apps.nix`. Run them as `nix run .#<name>`; from
another machine use `github:smores56/nix-config#<name>`.

### bootstrap

<!-- manual-step: app/bootstrap -->

Fresh machine (requires only Nix): clones the repo via ghq, switches
home-manager, writes the committed SSH public keys, and on NixOS applies the
system configuration. It never logs in: it prints `gh auth status` at the end
and leaves the interactive login to the operator, after which git and `gh` use
each account's sops PAT. `bootstrap.sammohr.dev` is not provisioned by this
repo; use the flake app.

### install

<!-- manual-step: app/install -->

`nix run .#install -- <host> root@<ip>`. Runs nixos-anywhere and the host's
disko layout (wiping disks), generates and writes the host's `hardware.nix`, and
delivers `secrets/hosts/<host>/` into the new root. It refuses to run when that
directory is missing, when its key derives a recipient other than the
`&<host>` anchor in `.sops.yaml`, or when that key cannot decrypt
`secrets/<host>.yaml` (or `secrets/common.yaml`): restore the identity with
`nix run .#key-restore -- <bundle> --host-key` first. Only a brand-new host
mints one (`nix run .#host-key -- <host>`, then `sops updatekeys`), and
`INSTALL_ALLOW_MISSING_HOST_KEY=1` is the explicit opt-out for a test machine
that should not read secrets. A LUKS host asks for its passphrase while disko
formats the disk. Extra arguments are forwarded to nixos-anywhere.

### host-key

<!-- manual-step: app/host-key -->

Generates the pre-generated host SSH key under the gitignored
`secrets/hosts/<host>/` and prints its age recipient. Add that recipient to
`.sops.yaml` as a key and as a `secrets/<host>.yaml` creation rule, then
`sops updatekeys secrets/<host>.yaml`.

### key-backup

<!-- manual-step: app/key-backup -->

Run `nix run .#key-backup` on a machine **before** wiping or reinstalling it.
It archives `~/.config/ssh-sk/k{1,2,3}/sudo` — the FIDO2 credential *handles*
that make the YubiKeys usable for sudo — the host SSH
key, and the untracked `~/wip/setup-yubikey.sh` if present. A machine wipe
destroys the handles; without them OpenSSH cannot use the credential even with
the right key inserted. The setup script is restored as **data** (0600), not
executable; review it and `chmod +x` after a restore.

The host key is read from its live location, `/etc/ssh/ssh_host_ed25519_key`,
which is 0600 root, so the run asks for `sudo` once. The checkout copy under
`secrets/hosts/<host>/` is only what `install` reads, never the source of truth.
The MANIFEST records `host-key: yes` and the derived age recipient, and the run
fails when that recipient is not `&<host>` in `.sops.yaml`. Run it from the
nix-config checkout: the recipient check needs that file, so running from another
directory is a refusal, not a skip. It also fails when the live key cannot be
read: a warning would let a wipe destroy the host's sops identity silently. Run
it from an interactive shell so the single `sudo` read can
prompt. `--no-host-key` is the explicit opt-out for a machine that has no host
identity of its own (the macOS laptops are home-only), and it is refused when
`.sops.yaml` binds `&<host>` to a key; `--host-key-path` points
at another key and exists for tests. If the key is ever lost, mint a replacement
with `nix run .#host-key -- <host>` and re-key `.sops.yaml`.

The private half of a FIDO2 credential and every PIV private key live on the
YubiKey and cannot be exported. No admin age key (`~/.config/sops/keys.age`),
PIN, or PUK is in the bundle; the enrollment script is bundled as data, so
review it.

Upload the printed `.tar.gz` and `.sha256` to a Bitwarden **note** item named
`nix-config restore bundle — <host>`, then remove the local copies (`shred -u`
on Linux, `rm -P` on macOS). Keep the archive and its checksum together, with
the `.sha256` named `<archive>.sha256`;
the file holds a bare hash, so renaming both together still works. The restore
refuses to proceed without it. An incomplete backup fails and names the missing
handles; `--allow-incomplete` archives a deliberate partial set. Do not wipe
until the handle count matches the inventory in `modules/lib/yubikey-keys.nix`
(six today).

None of that protects the host key the bundle now carries: it is a plaintext
private SSH key. Reading the Bitwarden item is enough to impersonate `<host>` and to
decrypt every secret that host is a recipient of — no YubiKey, PIN, or touch
involved. The admin age key stays out of the bundle; the host identity does not.

### key-restore

<!-- manual-step: app/key-restore -->

Download the two files from the Bitwarden item. Two modes, in this order:

```sh
# In the operator checkout, BEFORE install: put the host key where install reads it
nix run .#key-restore -- ~/Downloads/<host>-restore-<time>.tar.gz --host-key

# On the new machine, after bootstrap: restore the FIDO2 handles
nix run .#key-restore -- ~/Downloads/<host>-restore-<time>.tar.gz
```

`--host-key` writes only `secrets/hosts/<host>/etc/ssh/ssh_host_ed25519_key`
(0600) and its public half (0644). It must run inside the checkout and it fails
closed: no `.sops.yaml`, no
`&<host> <age1...>` anchor, or a key that derives a different recipient all
abort — there is no flag to skip that check, because installing such a key
produces a host that cannot read its own secrets. `--force` only replaces
existing files. The default mode never installs the host key.

It verifies the outer checksum, refuses to overwrite existing handles or the
script without `--force`, and checks every handle's public half and application
against the committed keys in `modules/lib/yubikey-keys.nix` before writing
anything. The checksums detect corruption, not tampering: an attacker who can
rewrite the Bitwarden item can rewrite the `.sha256` too. The `&<host>` anchor in
`.sops.yaml` is the only authenticity control, and only `--host-key` enforces
it. It does not inspect the touch/PIN flags, which live in the private
file; a flagged credential is still bound to the same token. `--no-verify` skips only the outer checksum; it cannot skip the
committed-key check. Then run `home-manager switch` if bootstrap did not
already write the public keys, and verify with `ssh smortress true` and
`ssh -t smortress sudo true`. The first signature prompts for the PIN once
(a dialog, or the terminal when no compositor runs).

### cloudflare-plan

<!-- manual-step: app/cloudflare-plan -->

`sudo nix run .#cloudflare-plan` runs a read-only plan from the root-only state
directory. Run it after any change to `tofu/` and after rotating the token.

### cloudflare-apply

<!-- manual-step: app/cloudflare-apply -->

`sudo nix run .#cloudflare-apply` applies the reviewed plan. Never apply on a
fresh state directory before importing existing objects; `prevent_destroy`
protects the applications and policies, but a wrong plan can still create
duplicates.

### cloudflare-tofu

<!-- manual-step: app/cloudflare-tofu -->

`sudo nix run .#cloudflare-tofu -- <args>` runs raw `tofu` in the state
directory, for `import`, `state list`, `state rm`, and recovery.

## Alert paths

Alert paths come from `tofu/main.tf` (notification policies) and from the
`alerting` module (`cloudflare-email@`). All of them email `sam@sammohr.dev`
through Cloudflare Email Service; no listener runs on the host. A Cloudflare
outage silences email and the tunnel together — the console is the fallback.

### unit-failure

<!-- manual-step: alert/unit-failure -->

Every backup unit's `OnFailure` starts `cloudflare-email@%n.service`, which
emails the unit's status and last 50 journal lines. Test the path without
breaking a backup:

```sh
sudo systemctl start cloudflare-email@restic-backups-r2.service
```

That sends one email about the (successful) unit; a real failure sends one per
failed run. The template reads the token from
`/run/secrets/cloudflare-api-token`.

### tunnel-health

<!-- manual-step: alert/tunnel-health -->

OpenTofu `cloudflare_notification_policy.tunnel_health` alerts on health events
for the configured tunnel. It is provider-side, so there is no local test;
confirm the policy in the dashboard after `cloudflare-apply`.

### service-token-expiry

<!-- manual-step: alert/service-token-expiry -->

OpenTofu `cloudflare_notification_policy.service_token_expiry` warns before an
Access service token expires. Renew the token in the dashboard, update the
clients that embed it (Bitwarden, per host), and re-run `cloudflare-plan`.

## Mail (Tuta)

`sam@sammohr.dev` is the primary address on a Tuta custom domain; `sammohr97@`
and `telhaturz@` are aliases (unlimited addresses on the custom domain) and a
catch-all is available. Tuta has no IMAP and no server-side SMTP submission: the
desktop client is the only way to import, search and send, and the phone uses the
Tuta app.

DNS records:

- `MX 10 mail.tutanota.de`
- `TXT @ v=spf1 include:spf.tutanota.de -all` and `TXT @ t-verify=…`
- `CNAME s1._domainkey → s1.domainkey.tutanota.de`, same for `s2`
- `CNAME _mta-sts → mta-sts.tutanota.de`, same for `mta-sts`
- exactly **one** apex `_dmarc` TXT (`v=DMARC1; p=quarantine; adkim=s`); a second
  record makes the policy invalid.

Tuta shows the records it wants under Settings → Global Settings → Custom email
domains. Every one of those CNAMEs must be **DNS only** in Cloudflare: a proxied
CNAME is answered as Cloudflare A/AAAA addresses, so the provider's checker says
"add value", DKIM fails, and the MTA-STS policy fetch lands on our tunnel instead
of Tuta's host. With the proxy off, `_mta-sts` chains to `v=STSv1; id=…` and
`https://mta-sts.sammohr.dev/.well-known/mta-sts.txt` returns Tuta's
`mode: enforce` policy for `mx: mail.tutanota.de`.

Forwarding in (two Gmail accounts):

1. The destination must exist: Settings → Email → Email addresses → Show → +,
   choosing the custom domain. Set `sam@` as the primary address.
2. Confirm the forward at the receiving end. Gmail mails a "Forwarding
   Confirmation" from `forwarding-noreply@google.com` with a link. Open it in Tuta; if it does not appear, check Spam, then resend from
   the source account. An unconfirmed forward silently forwards nothing.
3. Sort it: Settings → Email → Show inbox rules → +, field **To recipient**,
   value the alias, target folder. One rule per forwarded account; values accept
   regex. Do not key on the sender — Gmail forwarding keeps the original `From`.
4. Auto-forwarding breaks the sender's DMARC: the envelope becomes the
   forwarder's while `From` stays the original domain, so mail from a sender
   publishing `p=reject` without DKIM can be dropped or quarantined on arrival.
   That is inherent to forwarding; watch Spam.

The host sends alerts through Cloudflare Email Sending only, from
`alerts@send.sammohr.dev` to `sam@sammohr.dev`; the sending subdomain carries its
own SPF (`cf-bounce.send.sammohr.dev`). Tuta is receive-only for this host.

**Signing check** (after any change to the sops signing keys or the git config):
`home-manager switch --flake .#smores@<host>`, then in any personal checkout
`git log -1 --format=%G?` must print `G`. If it does not, check
`/run/secrets/github-personal-signing-key` (mode `0400`, owned by the user) and
`~/.config/ssh/allowed_signers`.

## Kanbei retirement cutover (T9)

The switch is `kanbeiSplit.cutover.enable` (`modules/kanbei-split.nix`), default
`false`. On the default generation nothing changes: the agent microVM, Letta,
Open WebUI, files-mcp and both laptop chat proxies are live. The table in
`docs/kanbei-split.md` lists every component and its follow-up deletion.

Do not flip it until the cluster serves the assistant end to end and the
private-data cutover has happened. Then, in order:

1. **Stop the legacy runtimes.** This is a normal `nixos-rebuild switch` on the
   next generation, but stop the guest first so its state is quiesced:

   ```sh
   sudo systemctl stop microvm@agent.service || true
   sudo systemctl stop open-webui.service files-mcp.service || true
   ```

2. **Flip the option.** Set `kanbeiSplit.cutover.enable = true` in
   `modules/hosts/smortress/default.nix` (`nixosOptions`) and in
   `modules/hosts/smorespro/default.nix` (`nixosOptions` and `homeOptions`);
   smoreswork sets it in `homeOptions`. Rebuild the server, then each laptop:

   ```sh
   just switch smortress
   just switch smorespro
   just home-switch sam smoreswork
   ```

   The switch removes `microvm@agent`, the broker/ingress/tap units, the
   `agent-vm-*` timers and sockets, `open-webui`, `files-mcp`, and the
   `chat-proxy` user unit/launchd agent. It also restores the ordinary fish
   login shell and drops the forced agent key on smortress, and stops restic
   from walking the retired assistant/Letta state paths.

3. **Verify the retirement.** Evaluation fails if anything survives; on the
   live host:

   ```sh
   systemctl status microvm@agent open-webui files-mcp    # each: not found
   systemctl --user status chat-proxy                     # smorespro: not found
   nix eval --raw .#nixosConfigurations.smortress.config.system.build.toplevel.drvPath
   ```

4. **Delete the code in a follow-up commit.** Use the exact file list in
   `docs/kanbei-split.md` ("Follow-up deletion list"). Keep
   `modules/nixos/kanbei-cutover.nix` until that commit lands, then remove the
   option and its assertions with the rest.

5. **Delete the encrypted key.** With the YubiKey present (`jupyter-token` was
   already deleted with the Open WebUI retirement):

   ```sh
   sops secrets/smortress.yaml          # delete github-repo-pat
   sops updatekeys secrets/smortress.yaml
   ```

   `manual-steps-sync` keeps a `secret/*` anchor while the key remains in the
   file; delete the anchor in the same commit that removes the key.

6. **Revoke the credentials.** Delete the classic `repo`-scoped GitHub PAT
   (Settings → Developer settings → Personal access tokens); the platform
   CronJob uses its own fine-grained read-only token. Rotate or revoke the
   Cloudflare Access service tokens only if the laptop chat proxies are no
   longer wanted; `cloudflared` on each laptop still needs
   `cloudflare-access-ssh-token`.

7. **Clean the data.** `/var/lib/data/open-webui` and the assistant/Letta state
   under `~/.local/state/` are plain restorable data; take one final backup,
   then remove them. The `agent` Access application and hostname route are
   deleted with the `tofu` follow-up in the retirement table.
