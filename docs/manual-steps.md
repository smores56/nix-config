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
- **Agent VM**: `a` runs maki in the microvm guest. The guest also gets the
  music, books and agent-ingest trees (`agentVm.extraShares` in the host's
  `default.nix`); `/var/lib/data/photos` and the vault are never shared. See
  [Agent VMs](#agent-vms).
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
which fails closed, so the first connection fails until this is done:

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

### cloudflare-api-token

<!-- manual-step: secret/cloudflare-api-token -->

One root-only token shared by OpenTofu and the email alert sender. Mint it at
<https://dash.cloudflare.com> → My Profile → API Tokens with:

- Zone:DNS:Edit for `sammohr.dev`;
- Zone:Rulesets:Edit for `sammohr.dev` (the `dav` rate-limit ruleset);
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

Per-host Cloudflare Access service token for `cloudflared access ssh`, exported
as `TUNNEL_SERVICE_TOKEN_ID` and `TUNNEL_SERVICE_TOKEN_SECRET`. The value is two
lines: the client ID, then the client secret. `cloudflared-access`
(`modules/features/cloudflared.nix`) reads it only from the host's sops
deployment: `/run/secrets/cloudflare-access-ssh-token` from sops-nix on NixOS,
and the sops-nix user path on Darwin. A missing, unreadable or malformed file is
a hard failure; there is no cache or password-manager fallback.

A NixOS declaration must hand the user access (`owner`/`mode`), because the
proxy runs as the user; `modules/hosts/smorespro/secrets.nix` is the example.

Mint one token per client machine under Zero Trust → Access → Service Auth, then
paste both lines as `cloudflare-access-ssh-token` in that host's file
(`secrets/smorespro.yaml`, `secrets/smoreswork.yaml`). The `service_auth` policy
accepts any valid service token, so no `cloudflare-apply` is needed; the
`expiring_service_token_alert` notification covers expiry.

### github-repo-pat

<!-- manual-step: secret/github-repo-pat -->

Classic `repo`-scoped token, root-only, read by the GitHub mirror and metadata
units (`tokenFile` in `modules/nixos/github-backup.nix`): ghorg, `python-github-backup`, and the
verifier (`gh`, via `GH_TOKEN` in its environment). ghorg embeds it in git's
argv, so it is visible in `/proc/<pid>/cmdline` during a run; the backup guide
records that accepted window. pgb receives it as a `file://` path, so it stays
out of argv. Fine-grained tokens cannot read wikis, so `--clone-wiki` would
silently omit them. Mint at GitHub → Settings → Developer settings → Personal
access tokens.

The mirror's probe repo (`sdlc`) must be refreshed on every run; a token
that is valid but has lost `repo` scope fails the run. The verifier also fails
when the token's repo listing no longer matches the mirror, so a scope loss is
caught the same night.

### calibre-password

<!-- manual-step: secret/calibre-password -->

OPDS password for the single `smores56` user, user-readable. The service
re-applies it on every start, so rotating is: edit this key, rebuild,
`systemctl --user restart calibre-server` (a rebuild does not restart a user
unit whose definition is unchanged) and refresh OPDS clients.

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

### Radicale htpasswd

<!-- manual-step: secret/radicale-htpasswd -->

One bcrypt line from `htpasswd -nB smores`, owner `radicale`, 0400. Rotation:
regenerate, update `secrets/smortress.yaml`, rebuild, and re-add the account in
DAVx5/khal.

### Jupyter token

<!-- manual-step: secret/jupyter-token -->

Random 32 bytes in `secrets/smortress.yaml`, 0400 owned by `smores` (the
sandboxed Jupyter unit runs as that user), read by the Jupyter server and
injected into Open WebUI's environment file. Rotation invalidates running
kernels.

### Memory MCP token

<!-- manual-step: secret/memory-mcp-token -->

Random 32 bytes in `secrets/common.yaml`, user-readable 0400. Presented as
`Authorization: Bearer` by Maki, the memory CLI/shim, and Open WebUI. Rotation
requires restarting `memory-mcp`, Maki, and Open WebUI.

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

Mint a new classic `repo` token (web). Then replace the secret, rebuild, and
prove it with a mirror run — a valid token that lost `repo` fails the run:

```sh
sudo systemctl start github-mirror.service
journalctl -u github-mirror.service -n 50
```

Revoke the old token. The mirror keeps the old value until the next run, so the
run above is the proof.

#### calibre-password

The single `smores56` OPDS account. `modules/features/calibre.nix` re-applies
the password in `ExecStartPre` on every start of the user unit `calibre-server`,
and a rebuild does not restart a user unit whose definition did not change:

```sh
sops secrets/smortress.yaml          # replace calibre-password
sudo nixos-rebuild switch            # redeploys /run/secrets/calibre-password
systemctl --user restart calibre-server
```

Refresh the OPDS clients' saved credentials.

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
OpenTofu manages a wildcard proxied CNAME, the `ssh`/`llm`/`memory` Access
applications, the email allow-list and service-auth policies, and the
tunnel-health and service-token-expiry notifications.

Manual, one-time (dashboard):

- Create the tunnel and store its credentials (see
  `cloudflared-credentials`).
- Mint the Access service token(s) used by unattended clients; the service-auth
  policy references them. OpenTofu does not create tokens. One
  `any_valid_service_token` policy covers `ssh`, `llm`, and `memory`, so any
  service token in the account reaches all three endpoints.
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

Personal files live in a Cryptomator vault that Syncthing replicates as
ciphertext. The device table is
[`modules/syncthing-devices.nix`](../modules/syncthing-devices.nix): device IDs
are public keys, so they are committed, and each device's `key.pem` is the only
secret. Every host sets `syncthing.device` in its `default.nix`, naming its row in that
table.

Pairing a device:

1. Install Syncthing. Android: the `researchxxl/syncthing-android` fork from
   F-Droid/Obtainium, and grant the battery-optimisation exemption — without it
   the folder stops syncing once the screen is off. macOS: home-manager's launchd
   agent; never the menu-bar app alongside it, because two instances share one
   config directory.
2. Read the device ID: `syncthing device-id` on a Linux/macOS host, the app's
   settings screen on Android.
3. Add it to the table, set `syncthing.device` on the new host, and rebuild.
   `overrideDevices`/`overrideFolders` are on, so the table and the folder are
   the whole truth and a click in the UI does not survive the next activation.

The vault is `~/Sync/vault` on laptops and `/var/lib/data/vault` on smortress.
It is ciphertext everywhere; plaintext exists only inside an unlocked client.
`vault <cmd>` prompts, mounts the vault into a temp dir, runs the command, and
unmounts on exit, so nothing stays mounted between uses. Linux mounts through
FUSE; macOS through fuse-t, which macOS may ask you to approve once in System
Settings, Privacy & Security.

**One device at a time.** Unlock on one device and leave the others read-only.
Two devices that create the same directory at once write two `dir.c9r` values,
and the loser becomes an orphaned content directory that only Cryptomator's
vault health check can recover, into `LOST+FOUND`. Password changes obey the same
rule: change it on one device, let Syncthing converge, then unlock the next,
because the old `masterkey.cryptomator.*.bkup` copies in the folder keep the old
password valid forever.

**Version history** is Syncthing staggered versioning at
`/var/lib/syncthing-versions/vault` on smortress — outside `/var/lib/data`, so
restic never carries it. Restore by copying the versioned file back into the
vault and letting it converge. The version file is ciphertext under its own
`~YYYYMMDD-HHMMSS` suffix; strip the suffix when copying it back, never decrypt
it. A `*.sync-conflict-*` file appearing in the decrypted view is the expected
outcome of a two-device edit: Syncthing keeps both copies, the conflict copy
decrypts to a normal readable name (`name.sync-conflict-<date>-<device>.<ext>`),
and it is resolved by hand. One copy per version that cannot be merged, so if a
device was paused across several remote changes (a restore plus more than one
save) expect more than one conflict file; keep the newest and delete the rest.

## Agent VMs

Agents run inside a VM on every host, so nothing they do can reach the host's
sudo, polkit, YubiKey, PIN or admin prompts. `a` starts one: `agent-sandbox
maki` on Linux, `agent-sandbox claude` on smoreswork. Plain `maki` or `claude`
on the host is the deliberate unsandboxed opt-out. The design and its accepted
risks are on smores56/sdlc#386.

Each guest sees the home at the same path, minus a deny list (`agentVm.deny` in
`modules/nixos/agent-vm.nix`; `deny` in `modules/features/agent-vm/default.nix`
on the Mac). Everything else is read-only except the `rw` list. Visible on
purpose: shell histories, agent transcripts, and credential files in shared
paths. What is not shared: browser profiles, keyrings, `~/.config/sops`, key
backups, clipboard history, `~/Library` on the Mac, and `~/Sync` on Linux. The
writable trees include repos, and the agent may write their `.git/config` and
hooks, which you later run on the host; that is accepted (full git for agents).
Keep secrets out of shared paths: run `secret-sweep` after adding files under
the home and move or delete what it reports.

### Linux (smortress, smorespro)

A microvm.nix NixOS guest that starts at boot (`microvm@agent.service`).
`agent-vm-prep` assembles the guest's home view on a tmpfs before each start,
and virtiofsd writes every guest file as you (guest root included), so guest
root cannot plant root-owned, setuid-root or device files on the host. The
sops secrets in `agentVm.secrets` are copied into a read-only share at
`/run/secrets`; the others never leave the host. The guest builds with its own
store layered over the host's, never the host daemon.

Network: tap `vm-agent` (host `10.77.0.1`, guest `10.77.0.2`). The guest
reaches the internet through NAT and, on the host, only the LLM and memory
ports, through socket proxies; it cannot reach other host services or the LAN.

After a host switch, the guest keeps running its old config; running sessions
survive. Pick up guest changes or new top-level home entries with:

```sh
sudo systemctl restart microvm@agent.service
```

`agent-vm-check` (also `just agent-vm-check`) asserts the boundary from inside
the guest: denied paths absent, read-only and writable shares behave,
hand-in secrets readable, guest files owned by you, `mknod` refused, host sshd
unreachable, the memory proxy reachable. Run it after changing the module.

The agent's maki state lives in `~/.local/state/agent`, `~/.local/share/agent`
and `~/.cache/agent` (the launcher points the XDG dirs there), so `ms` resumes
guest sessions through `agent-sandbox`. maki is installed manually in
`~/.local/bin`.

The personal sops signing key logs in to smortress only through a forced
`agent-ssh` command, which lands in smortress's own guest, never a host shell.
A laptop guest reaches smortress that way through the tunnel.

### smoreswork

A headless Tart macOS guest (`modules/features/agent-vm`). Once per Mac:

1. Turn off AirPlay Receiver (System Settings → General → AirDrop & Handoff):
   it is the one host service the guest can reach that can pop a dialog.
2. Narrow Docker Desktop's File sharing (Settings → Resources → File sharing)
   to the shared trees (`~/Blitzy`, `~/repos`). Containers started through the
   forwarded socket can mount whatever is listed there, `/Users` included.
3. Run `agent-sandbox provision` (clones the pinned image, hardens the guest,
   rotates its admin password, installs the login key), then `a` and sign in to
   Claude inside the guest; the guest keeps its own login.

`agent-sandbox restart` stops the VM so the next launch re-plans the shares;
`agent-sandbox stop` shuts it down. The four `github-{personal,work}-{pat,signing-key}`
secrets are handed in at the host's sops-nix path on each launch; the rest stay
on the host. Docker comes from the host's Docker Desktop through a per-session
forwarded socket, so Docker Desktop must be running.

### Scrub at source

`secret-sweep` (offline, redacted gitleaks) scans the home, skipping `~/Library`
on the Mac. Run it on each host, then delete or move each finding out of the
shared paths. Credentials that were only ever needed by humans are better
revoked than hidden: the two work GCP service-account keys
(`dev-service-account@blitzy-os-dev`, `@blitzy-platform-stage`) were removed
locally; revoke them in IAM only after confirming with the team that nothing
else (CI, teammates) uses them.

### immich-agent-api-key

<!-- manual-step: secret/immich-agent-api-key -->

Scoped Immich API key for the agent, user-readable in `secrets/common.yaml`.
Create it in Immich under Account Settings → API Keys with **asset.read,
asset.upload, album.read, album.create** only — no asset delete, no user or
admin scope. The agent VM hands it in at `/run/secrets/immich-agent-api-key` and the
launcher exports `IMMICH_API_KEY` (`secretEnv` in `modules/lib/agent-vm.nix`).
`/var/lib/data/photos` is never shared into the guest, so the agent uploads
through the API only and never sees the managed library.

To rotate: create the new key in Immich, update the common file, rebuild both
hosts so sops rewrites `/run/secrets/…`, then delete the old key in Immich.


## Public services

Services come from `webProxy.services` on each NixOS host. Each becomes
`<name>.<domain>` through the tunnel. `ssh`, `llm`, `memory`, and `chat`
have Cloudflare Access applications (hand-written in `tofu/`); `access.enable`
on any other service fails evaluation. Calibre and Immich are public and rely
on their own app auth.

### smortress/calibre

<!-- manual-step: service/smortress/calibre -->

`calibre.sammohr.dev` → loopback `ports.calibre`, HTTP, public (no Access).
OPDS clients authenticate as `smores56` with `calibre-password`.

### smortress/immich

<!-- manual-step: service/smortress/immich -->

`immich.sammohr.dev`, public (no Access) and protected by Immich's own login.
The first user to register becomes the admin, so register it immediately after
the first start — anyone who reaches the instance first takes the account.
Phones also use the LAN URL
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
   `appendonlydir.pre-restore-<timestamp>` (Redis prefers the AOF) and FalkorDB
   restarts. Otherwise the registry is restored alone.

Delete the `*.pre-restore-*` files once `GRAPH.LIST` and a search confirm the
result. Flags: `--dry-run` verifies and prints the plan; `--no-stop` is accepted
only with `--dry-run`; `--start` starts the services afterwards; `--owner
user:group` (default `memory:memory`, empty skips). A restore holds
`<state>/.restore-in-progress` and `memory export` refuses to run while it
exists; a failed restore leaves it, so remove it after reconciling.
`tests/memory_export_restore.sh` runs the same procedure against temp
directories.

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

### smortress/chat

<!-- manual-step: service/smortress/chat -->

`chat.sammohr.dev` → the loopback Open WebUI server (`ports.openWebui`), HTTP
behind Access plus Open WebUI's own email/password login. It is the phone PWA
and the desktop web app; SQLite, uploads and the workspace live under
`/var/lib/data/open-webui`, so restic covers them with the durable tree.

Two OpenAI-compatible backends are declared in `modules/nixos/open-webui.nix`,
index-aligned with their keys: local llama.cpp (`qwen3.8-27b`, keyless, works
with no network) and Neuralwatt (`deepseek-v4.1-flash`, the default through
`DEFAULT_MODELS`). The Neuralwatt key reaches the unit only through the rendered
sops environment file, never the Nix store. Open WebUI has no automatic
failover, so the local model is a manual pick, not a fallback chain.
`ENABLE_PERSISTENT_CONFIG` is off: every connection, tool server and engine
below comes from the environment, and edits made in the admin UI do not survive
a restart. Model ids are bare unless a connection sets `prefix_id`, so
`DEFAULT_MODELS` must match what the picker lists.

**Tool servers** are `ConfigVar`s in `TOOL_SERVER_CONNECTIONS`, type
`MCP (Streamable HTTP)`. The memory wrapper is registered with its sops bearer
token at `http://127.0.0.1:8182/mcp`. Open WebUI cannot send the `X-Memory-*`
headers, so the deployment pins one scope for clients that send none
(`MEMORY_MCP_DEFAULT_GROUP=global`, `MEMORY_MCP_DEFAULT_CWD=/chat`,
`MEMORY_MCP_DEFAULT_ACTOR=open-webui`, `MEMORY_MCP_DEFAULT_MACHINE=smortress`);
that keeps chat writes in the shared group and labels them, while searches read
every allowed group. Maki and the CLI keep the strict header contract.
`files-mcp` (`http://127.0.0.1:8185/mcp`) needs no token. A
malformed value is silently dropped by Open WebUI, so an empty External Tool
Servers list means the JSON is broken.

**New chats start with every tool on.** `DEFAULT_MODEL_METADATA` gives each
model `capabilities.{web_search,code_interpreter}`, `defaultFeatureIds` for both
features and `toolIds = [server:mcp:memory, server:mcp:files]`. The backend
merges it into every model's `info.meta` when the list is built (`capabilities`
merge, per-model values winning; other keys are fill-only), and the chat UI seeds
a fresh chat from exactly those fields. Tool ids are `server:mcp:<info.id>`, so
renaming a server's `info.id` breaks the default silently. Existing chats keep
their own toggles; only new ones pick this up.

**Code interpreter** is Jupyter in a bwrap sandbox (`modules/lib/jupyter-sandbox.nix`)
(loopback `8888`, token from the `jupyter-token` secret), so generated code runs
with the vault, `~/Sync` and the host secrets masked. **Web search** goes to the
TinyFish shim on loopback `8899` because the bundled engines are unmaintained
scrapers; the shim holds `tinyfish-api-key` and returns the bare array the
`external` engine expects.

**Chat is browser-only.** The Access application admits the email allow-list
and no service token, and nothing in the stack calls Open WebUI's
OpenAI-compatible API: Maki reaches llama.cpp and Neuralwatt through its own
provider config, so no API key is issued.

For the first deployment, apply the Access application before rebuilding:
`sudo nix run .#cloudflare-apply`, then `just switch smortress`.

### Phone file search

`files-mcp` is a read-only file-search MCP on loopback `ports.filesMcp` over
`/home/smores/{code,Documents,Downloads,dev}`. Open WebUI registers it as a
second tool connection (`http://127.0.0.1:8185/mcp`, no auth) in
`TOOL_SERVER_CONNECTIONS`, so chats get its tools with no setup.

Tools: `file_search` (file names and contents), `file_read` (one file, with
line numbers), and `file_list`. Paths outside the roots, secret-like files
(`.env*`, keys, `.ssh`, `.gnupg`), and employer checkouts are refused; the
employer check reuses memory's markers, so `smores.flow=pr` or a `blitzy-*`
remote is enough. `.git`-ignored trees are skipped, which includes unmerged
`.worktrees` checkouts; a file that exists only on an unmerged branch is not
searchable until it is on the checked-out tree.

### smortress/ssh

<!-- manual-step: service/smortress/ssh -->

`ssh.sammohr.dev`, SSH to the loopback sshd (key-only), with service auth for
`cloudflared access ssh`. `ssh` must keep Access enabled; evaluation fails
otherwise.

`smortress` logs in with the PIV keys in slot 9a through the laptop's PIV agent,
which `piv-ensure` (the ProxyCommand) loads on first use and reloads from the
login-session PIN cache after another PIV client reset the card session. The
forwarded agent holds only the touch-only sudo handles.

### dav.sammohr.dev

<!-- manual-step: service/smortress/dav -->

Radicale over the tunnel at `https://dav.sammohr.dev/`, public with its own
bcrypt auth; CalDAV clients cannot complete an Access login. The zone's
rate-limit ruleset (`dav_rate_limit` in `tofu/main.tf`) is managed by
`nix run .#cloudflare-apply`.

### music.sammohr.dev

<!-- manual-step: service/smortress/navidrome -->

Navidrome at `https://music.sammohr.dev/`, public with its own auth and under
the same per-IP rate limit as `dav`. Create the first account in the web UI; it
becomes the admin.

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
`chat` fails evaluation, and OpenTofu has `prevent_destroy` on those apps and
policies. A wrong *policy* (e.g. email) still locks out the browser: fix it in
OpenTofu, or in the dashboard as break-glass.

**sops cannot decrypt on smortress (host key lost).** Its age recipient derives
from `/etc/ssh/ssh_host_ed25519_key`. From a laptop with the admin identity, add
the replacement host recipient to `.sops.yaml` and run
`sops updatekeys secrets/smortress.yaml`.

**Recovery page (what the family opens).** In the Cryptomator app create
`Documents/sentinel.txt` with any canary text (`sentinel: 6f1c2a7e`), edit on one
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
key, and the untracked `~/dev/setup-yubikey.sh` if present. A machine wipe
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
