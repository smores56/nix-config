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
  (see Recovery in `README.md`).
- **Out-of-band access**: the physical console. There is no inbound SSH port;
  SSH is tunnel-only.
- **Maki sandbox**: `m` runs Maki through `agent-sandbox` (bubblewrap). The
  authoritative bind list is `homeRw`/`homeRo`/`configAllow`/`secretBind` in
  `modules/lib/agent-sandbox.nix`; it is wider than the identity dirs —
  `~/code`, `~/dev`, `~/Documents`, `~/Downloads`, `~/.cache`, the
  cargo/npm/bun caches and `/var/lib/media` are read-write, the nine
  allowlisted config dirs are read-only copies, and `~/.cache/.bun/bin` is
  read-only inside its writable parent — and
  the secret allowlist is six credentials (two PATs, Neuralwatt, TinyFish, the
  Immich key, and the Cloudflare Access token when present). `~/.ssh`,
  `~/.config/{ssh-sk,sops}`, the PIV/sudo agent, and every other
    secret are absent; no agent socket is forwarded in. `/var/lib/media/Photos`
 is masked
  by a tmpfs applied after every bind, so it reads empty and is not writable
  even though the media tree as a whole is.
- **Maki signing**: commits made inside the sandbox sign with the same sops key
  the host uses for that repo's owner (`user.signingkey`, `gpg.format=ssh`):
  the personal key is bound at its `/run/secrets` path on Linux, and on the work
  Mac the sandbox reads the resolved files behind `~/.local/share/github`. The
  sandbox git config sets `commit.gpgsign = true`, so signing is the default.
  `commit.gpgsign` is config, not enforcement: a deliberate
  `git commit --no-gpg-sign` still produces an unsigned commit, which the review
  or PR checks catch. A retired `~/.config/maki/signing_ed25519` is removed by
  `agent-sandbox-cleanup`; nothing reads it.

#### Encrypted root and Secure Boot (T2)

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

The migration ran two installed disks at once, so the staging system on the 970
used `EFI-tmp`/`root-tmp` labels: duplicate `EFI`/`root` PARTLABELs make
`/dev/disk/by-partlabel/*` resolve to whichever device udev saw last. The 970
keeps those labels as the rollback; the 980 owns `EFI`/`root`.

After a `db`/firmware change, replace the Clevis slot and re-export the JWE:
`sudo clevis luks unbind -d /dev/disk/by-partlabel/root -s <slot>`, re-run the
bind above, and regenerate `root.jwe`. Then **rebuild** (`sudo nixos-rebuild
boot`): lzbt embeds the JWE in the signed UKI, so without it the next boot
still uses the old token. An older generation keeps its older JWE too, so
rolling back after a re-bind prompts for the passphrase until it is rebuilt.

After the migration's `rsync --numeric-ids`, ownership is the source system's,
not this install's: Immich's user was `987:983` on the old root and is
`999:999` now. `chown -R immich:immich /var/lib/media/Photos` (and the
equivalent for each service) or the service gets `EACCES` on its own files.


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
   carries the host key) is in Proton Pass.
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

# 4. Recovery key: print it, store it off-site and in phone Pass. Do this
#    before enrolling the TPM.
sudo systemd-cryptenroll --recovery-key /dev/disk/by-partlabel/root

# 5. Home config, FIDO2 handles, SSH (fresh installs have no checkout yet)
nix run github:smores56/nix-config#bootstrap
cd ~/code/github.com/smores56/nix-config
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
lock-screen agent at `/run/user/1000/fido2-agent`, which `fido2-agent-load`
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
- **Measured on smorespro (2026-10-30):** lid-closed login 65 ms; lid-open
  5.39 s (the fingerprint wait); successful password 53 ms; failed attempt
  1.7–2.7 s.

The gates are `pam_exec` probes built with `pkgs.writeShellApplication` (store
paths that own their `PATH`). `pam_exec` passes an **empty** environment, so a
bare command exits 127 and the gate silently no-ops. The card probe is a build
input because a missing one runs `pam_p11` and its `default=die` would lock out
the password entirely. `pam-auth-gates` pins both full stacks and asserts
`sudo`/`su`/`polkit-1` carry no `p11`/`fprintd`/`exec`.

Noctalia's `passwordSent` guard landed in **v5.3.0** (PR #4294), not 5.4.1. The
strict stack never issues a second prompt, so the guard is unreachable and the
shell is no longer pinned for auth reasons; a shell upgrade is a separate
change.

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
manages the user environment.

## Tang Pi

smortress's root disk gets a Clevis `sss` policy (Tang share + TPM2 share bound
to PCR 7, T2 in #250). The Pi is not a NixOS host in this flake: it runs
Raspberry Pi OS (Debian trixie, aarch64) and only `tang`.

Threat model: Tang keys are plaintext on the Pi. A stolen disk alone, a live USB
on the LAN, or a Secure-Boot-off boot cannot unseal the TPM share; a thief who
takes the server and the Pi together decrypts. Keep the Pi patched, on the LAN
only, and never forward the Tang port through Cloudflare or the router.

Current server, recorded 2026-10-29:

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

`~smores/.ssh/authorized_keys` holds exactly two kinds of key:

- the smortress software key, `from="10.0.0.125,10.0.0.135"` (both smortress
  interfaces). The private half is `~/.config/pi/ssh/id_ed25519` on smortress
  (0600, outside Maki's sandbox, never committed). It is useless from any other
  source address.
- the three YubiKey PIV 9a public keys from `modules/lib/yubikey-keys.nix`, for
  the laptops. macOS prompts for the PIV PIN through OpenSC. On Linux the PIV
  provider is loaded on first use by `yk-ensure` (the `smortress` ProxyCommand);
  a direct LAN connection runs no proxy, so run `yk-login` once first:

```sh
# Linux laptop
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/fido2-agent" ssh -o IdentitiesOnly=yes \
  -i ~/.config/ssh-sk/piv-k1.pub -i ~/.config/ssh-sk/piv-k2.pub \
  -i ~/.config/ssh-sk/piv-k3.pub smores@10.0.0.193
```

`modules/features/cloudflared.nix` defines `Host tang-pi 10.0.0.193` for Linux
and macOS, so after a home-manager switch plain `ssh tang-pi` picks the PIV
identity (agent on Linux, PKCS#11 on macOS). Pin the host key once per laptop;
`SSH_ASKPASS_REQUIRE=force` correctly sends the `yes/no` prompt to the PIN
helper, which refuses it, so the first connection fails until this is done:

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
Clevis bind (T2 step 6) with the LUKS passphrase. Do not back the Tang keys up as
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

No host holds the admin identity, so edit from a laptop that has it:

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
`~/.config/sops/keys.age` on the operator's laptops (smorespro, smoreswork) and
nowhere else. smortress keeps only its SSH host key, so a compromised server
yields no identity that can re-encrypt `secrets/` or read anything already
committed.

`sops` receives the identity through `SOPS_AGE_KEY_CMD` → `sops-age-key` →
`age --decrypt ~/.config/sops/keys.age`. `age` prompts on the tty and sops reads
the identity from the wrapper's stdout, so the passphrase never lands in argv,
the environment, or the store, and one sops run costs one prompt.

Create it once on a laptop:

```sh
mkdir -p ~/.config/sops
(umask 077; age-keygen | age --passphrase -o ~/.config/sops/keys.age)
age --decrypt ~/.config/sops/keys.age | age-keygen -y   # prints the recipient
```

`age` creates the file `0644`; the subshell's `umask` keeps it `0600`.

Copy the encrypted file to another laptop as-is (the passphrase travels
separately). Put the recipient into `.sops.yaml` as `&admin`, then re-encrypt
the data key to the new recipient list:

```sh
sops updatekeys secrets/smortress.yaml   # one prompt; values are untouched
```

`updatekeys` re-wraps only the *data key*: an identity that already unwrapped
it keeps decrypting every current and future value. After the recipient swap,
rotate the data key itself so the retired identity is useless:

```sh
sops rotate --in-place secrets/smortress.yaml   # new data key, same values
```

Verify the laptop holds a working identity:

```sh
sops -d secrets/smortress.yaml > /dev/null   # one prompt, exit 0
```

**Move it off every host.** After copying `keys.age` to the laptops, delete the
copy on smortress along with any passphrase file next to it, then prove the
host holds no admin identity:

```sh
rm -f ~/.config/sops/keys.age /run/user/$(id -u)/age-*passphrase
test ! -e ~/.config/sops/keys.age
env -u SOPS_AGE_KEY_CMD sops -d secrets/smortress.yaml >/dev/null   # must fail
```

The wrapper refuses to run while a plaintext `~/.config/sops/age/keys.txt`
exists, because sops would load that default even with `SOPS_AGE_KEY_CMD` set.

**Passphrase custody.** Proton Pass plus an off-site copy on offline media (not
another machine). Keep the two apart; either alone is worthless. Losing both
means losing the identity — nothing can unwrap `keys.age`. The secrets
themselves survive (smortress's host key still decrypts them), so recovery is
minting a new identity and re-keying (below), not restoring the old one.

**Editing rule.** Every `sops` edit and `sops updatekeys` runs from a machine
holding `keys.age`. On smortress the wrapper fails, which is the point: edit or
rotate on a laptop, commit, then `sudo nixos-rebuild switch` on smortress. The
message is printed on the terminal, because sops swallows the command's stderr.
`SOPS_AGE_KEY_CMD` is a session variable, so reopen a shell that predates the
last switch.

**Replace the admin identity** (also the path after a lost passphrase or a
suspected leak):

1. Mint a new `keys.age` (above) and swap the `&admin` recipient in
   `.sops.yaml`.
2. Re-encrypt the data key to the new recipient list, then rotate the data key.
   From a laptop that still holds the old identity:
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

The work Mac decrypts at home-manager activation, which cannot prompt, so it
uses a plaintext age identity instead of the passphrase-wrapped `keys.age`. Its
recipient is `&smoreswork` in `.sops.yaml`.

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
- Email Sending:Edit.

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
a hard failure; there is no cache or Proton Pass fallback.

A NixOS declaration must hand the user access (`owner`/`mode`), because the
proxy runs as the user; `modules/nixos/secrets-smorespro.nix` is the example.

Mint one token per client machine under Zero Trust → Access → Service Auth, then
paste both lines as `cloudflare-access-ssh-token` in that host's file
(`secrets/smorespro.yaml`, `secrets/smoreswork.yaml`). The `service_auth` policy
accepts any valid service token, so no `cloudflare-apply` is needed; the
`expiring_service_token_alert` notification covers expiry.

### github-repo-pat

<!-- manual-step: secret/github-repo-pat -->

Classic `repo`-scoped token, root-only, read by the GitHub mirror and metadata
units (`githubBackup.tokenFile`): ghorg, `python-github-backup`, and the
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
NixOS, `~/.local/share/github/github-personal-signing-key` on the work
Mac. The public half is `personal` in `modules/lib/signing-keys.nix`; it is
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
only, linked at `~/.local/share/github/github-work-signing-key` on the
work Mac. The work owner include selects it there; personal hosts have no work
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

### Rotation checklist

The retired admin key could read every value here, so re-encryption alone is
not enough — rotate the upstream credential too. Per item: mint the new
credential, `sops secrets/smortress.yaml`, commit, `sudo nixos-rebuild switch`
on smortress, prove it, then revoke the old one. The tunnel credentials and the
rclone session are the two that are not a plain token swap.

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

cloudflared 2026.7.2 has no `rotate-secret` subcommand (`cloudflared tunnel
--help` lists login/create/route/run/list/…/token), so do not script this. The
dashboard's Refresh token rotates the token of a token-managed tunnel; whether
it yields a new `TunnelSecret` for this locally-managed tunnel is unverified, so
recreate the tunnel instead — from the console, since the tunnel is the only
path to the host. `AccountTag` stays (it is the Cloudflare account); `TunnelID`
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
(login) and every 3 h after that. Nothing to provision: the forwarded PIV agent
authenticates the rsync while the session's PIN cache is warm, and the timer
never opens a dialog (`YK_ENSURE_NO_PROMPT`), so a cold cache fails that run
instead of prompting.

smoreswork runs it from a LaunchAgent, which has no tty, so three operator
steps are needed once. `wallpapers` exports `SSH_ASKPASS` and
`SSH_ASKPASS_REQUIRE=force` on macOS, so a manual `wallpapers sync` uses the
same Keychain PIN and never sits at a terminal prompt; without the item it
fails closed instead of hanging.

1. Put the PIV login PIN in the login Keychain. `-A` lets the unattended agent
   read it without a dialog; anything else running as you can read it too, but
   the PIN alone cannot sign without the YubiKey.

   ```sh
   read -rs PIN && security add-generic-password -a "$USER" -s smortress-piv-pin -w "$PIN" -A && unset PIN
   ```

2. Approve the Automation prompt ("… wants to control System Events") the
   first time the agent sets a wallpaper. Until then the run fails and leaves
   the current wallpaper; it retries on the next interval.

3. Make sure `ssh smortress true` has succeeded once, so the host key is in
   `~/.ssh/known_hosts`: the job sets `StrictHostKeyChecking=yes`.

Verify from a terminal (prompts for the PIN) or kick the agent:

```sh
wallpapers sync
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.wallpapers
tail -n 20 ~/Library/Logs/wallpapers.log
```

When the PIV PIN changes, replace the Keychain item in the same step. A stale
PIN is sent to the card once per run, and the PIV retry counter locks after
three; update the item before that happens.

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
- Delete stale DNS records, Access applications, and policies left by the
  retired reconciler; it never deleted anything. Import any object you want to
  keep before the first apply.
- The personal-site Worker and the `keyboards.sammohr.dev` redirect are
  dashboard objects, not OpenTofu.

Every change: `sudo nix run .#cloudflare-plan`, review the plan, then
`sudo nix run .#cloudflare-apply`. State is root-only in
`/var/lib/cloudflare-tofu` and backed up as `CloudflareTofu`. `prevent_destroy`
guards the applications and policies; remove it deliberately if you mean to
delete them.

## Backup (restic)

restic is the driver: [`modules/nixos/restic-backup.nix`](../modules/nixos/restic-backup.nix)
defines two repos that hold the same snapshots from one source path,
`/var/lib/data`. The operator guide is
[`modules/features/backup/README.md`](../modules/features/backup/README.md).

| Repo | Target |
| --- | --- |
| `r2` | `s3:https://<account>.r2.cloudflarestorage.com/restic-backup` |
| `local` | `/var/backup/restic`, on the encrypted backup disk |

Nightly at 03:30 with up to 15 minutes of delay, `initialize = true`,
`--keep-daily 14 --keep-weekly 8 --keep-monthly 12`, and `restic check` after
every run. Both units start `cloudflare-email@%n.service` on failure. The
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

Both repos passed this drill on 2026-11-02 (267 GiB snapshots, 386 files; 2.34
GiB of wallpapers restored, hashes identical).

Restoring the Immich database from the same snapshot:

```sh
sudo restic-r2 restore latest --target /var/tmp/db-restore \
  --include /var/lib/data/db/immich.dump
sudo -u postgres createdb immich_restore
sudo -u postgres pg_restore --no-owner -d immich_restore \
  /var/tmp/db-restore/var/lib/data/db/immich.dump
```

### Encrypted backup disk

`/var/backup` on smortress is the 4.5T HDD (`ata-ST5000LM000-2AN170_WCJ42WX0`).
It is LUKS-encrypted: opened at boot from `/etc/crypttab` with a root-only
keyfile on the encrypted root (so boot stays unattended), with a LUKS passphrase
slot as the recovery path if the root is ever lost. The option is
`backup.luks` in [`modules/nixos/backup.nix`](../modules/nixos/backup.nix);
smortress turns it on in `modules/hosts/smortress/meta.nix` together with
`backup.device = "/dev/mapper/backup"`.

Formatting destroys everything on the disk. The R2 repo is the safety net, and
the local repo is derived: every byte in it comes from `/var/lib/data`, so the
recovery path is a fresh seed from the live sources or a restore from R2, never
a copy of the old disk. Do it in this order:

```sh
# 1. Prove the offsite repo first: snapshots exist and a sample reads clean.
sudo restic-r2 snapshots | head
sudo restic-r2 check --read-data-subset=2%

# 2. Stop the timers, then unmount the plain ext4 disk.
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

Then enable `backup.luks` and `backup.device = "/dev/mapper/backup"` in
`modules/hosts/smortress/meta.nix`, rebuild, and reboot: `/etc/crypttab` opens
the disk from the keyfile before the mount, `nofail` keeps a missing keyfile
from blocking boot, and the local unit (which declares `RequiresMountsFor`)
fails loudly instead of writing to the root filesystem.

The local repo is created on the next run (`initialize = true`), so nothing has
to be restored into it. After the reboot, seed it and start the timers:

```sh
sudo systemctl start restic-backups-local.service
sudo restic-local snapshots
```

Rotate the Cloudflare API token and tunnel credentials in the same session (see
the rotation checklist above), since they sat on the plaintext disk.

## Agent sandbox

`agent-sandbox <harness>` is the explicit same-UID boundary; `m` is a fish/zsh
abbreviation for `agent-sandbox maki`. Install `maki` manually in
`~/.local/bin` (there is no wrapper), and run plain `maki` only when you mean
to work unsandboxed. `agent-sandbox-check` runs the real boundary and asserts
the core properties.

The sandbox binds an explicit config allowlist and masks the whole `~/.config`;
if a tool needs its config, add the directory to `CONFIG_ALLOW` in
`modules/lib/agent-sandbox.nix`. `~/.ssh` contains no keys: `allowed_signers`
and `known_hosts` live in `~/.config/ssh`, and the home-manager activation
moves them there. The agent's SSH credential is the personal sops signing key,
and smortress authorizes it only with a forced `agent-ssh` command that
re-enters the sandbox.

One-time cleanup (already run for the personal hosts): `agent-sandbox-cleanup
--yes` deletes the retired Maki software signing key, the `~/.config/pi` SSH
key (tang-pi is console-only), the `~/.config/gh/hosts.yml` OAuth token, the
cliphist database, and the fish history. Remove the retired Maki signing key
from GitHub's signing keys afterwards.

Existing repos keep `.git/hooks` and `.git/config` read-only inside the
boundary, so the agent cannot install hooks or set `core.hooksPath`; the hooks
already in the repo still run for the agent. Repos it creates inside the
sandbox are writable and are reviewed like any other code. Renaming a repo's
`.git` still moves the read-only mounts with it, so this is a raised bar, not a
kernel boundary.

Residuals of the same-UID model: `~/.cargo/registry`, `~/.cargo/git`, `~/.npm`,
and the Bun cache stay writable for build speed, so a modified cache entry can
affect a later unsandboxed build; `~/.local/state/*` entries that are not
explicitly masked remain readable read-only; and the sandbox holds the signing
keys by design, so review and the PR gate stay the control.

Nix: `/nix/store` is read-only, and so is `/nix/var/nix` whenever a daemon
socket exists, so `nix` resolves to the daemon instead of a local store. A local
store would take its lock files inside the read-only store and fail; the state
dir bwrap creates is writable, which is exactly what makes `store = auto` choose
it. The socket was always reachable, so this only makes the daemon the default:
agent builds run in the daemon's sandbox as `nixbld`
(`nix.settings.build-users-group` in `modules/nixos/base.nix`) and the paths
they add persist in the host store.

The config allowlist is read-only, but `CONFIG_WRITABLE` in
`modules/lib/agent-sandbox.nix` lists files a tool must lock or rewrite. Each
gets a writable copy under the agent state bound over the read-only file —
currently only `maki/pack-lock.json.lock`, so maki's package lock works while
the plugin config stays immutable. The host sidecar is created empty if absent
(maki creates the same file itself).

Clipboard history is deliberately not persisted: the cliphist database is
removed and the sandbox masks `~/.cache/cliphist`. There is no same-UID
permission that makes a live history unreadable without root; not storing it is
the only reliable hardening.

Photos: the agent talks to Immich over its API rather than touching
`/var/lib/media/Photos`, using `secret/immich-agent-api-key` (below).

Work Mac: create the Keychain item `maki-openai-api-key`; the host-side
launcher reads it before entering the sandbox because `securityd` is denied
inside. GitHub needs no Keychain item: the sandbox reads each account's sops
PAT and signing key through `~/.local/share/github`, selected by the target
repository's owner, so delete any old `maki-github-pat` item with
`security delete-generic-password -s maki-github-pat`. The Seatbelt profile allows those files'
resolved paths as they are at launch, so relaunch a long-running sandbox after
sops-nix re-decrypts (a `home-manager switch` that changes secrets, or the
`launchctl kickstart` below).

### immich-agent-api-key

<!-- manual-step: secret/immich-agent-api-key -->

Scoped Immich API key for the agent, user-readable in `secrets/common.yaml`.
Create it in Immich under Account Settings → API Keys with **asset.read,
asset.upload, album.read, album.create** only — no asset delete, no user or
admin scope. The sandbox binds it into the boundary at `/run/agent/immich-key`
and exports `IMMICH_API_KEY` (`read_secret` in `modules/lib/agent-sandbox.sh`);
nothing outside the sandbox reads it. `/var/lib/media/Photos` is masked by a
tmpfs inside the boundary, so the agent uploads through the API only and never
sees the managed library.

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

`memory.sammohr.dev` → the loopback memory wrapper (`ports.memoryMcp`), TCP to
the server's loopback, with the same service-auth policy. The wrapper derives
nothing itself: it validates the group header the Maki shim sends, refuses work
groups, enforces a 60s deadline per tool call, and is the only tunnel target.
MCP tool calls are authenticated by Access alone. Raw Graphiti runs on an
internal loopback port in `modules/nixos/memory.nix` and is never tunneled. The
wrapper owns the typed registry, verifies queued writes against FalkorDB, and
exposes `/internal/episodes` and `/internal/lookup` for `memory ingest`.

Those two ingest routes carry a second gate. The tunnel is a raw TCP forward,
so the wrapper sees `127.0.0.1` as the peer for every tunneled request and the
loopback check can never tell a tunneled client from a local one. At startup
the wrapper mints a random token into `/var/lib/memory/internal.token`
(mode 0640, owned by the `memory` service group) and requires
`Authorization: Bearer <token>` on both routes; the loopback check stays as
defence in depth. `memory ingest` reads the same file, so the human user must
be in the `memory` group — `modules/nixos/memory.nix` adds
`users.users.<machine.username>.extraGroups` when `memory.enable` is set, and
the membership only applies after `just switch smortress` **and** a fresh login
session (or `newgrp memory`). `MEMORY_INTERNAL_TOKEN_FILE` overrides the path,
which matters only for a deliberate run from another host: the token is
regenerated on every wrapper start, so a copied file goes stale.
`/internal/lookup` takes at most 10,000 hashes and both routes reject bodies
over 1 MB.

The FalkorDB and Graphiti containers run rootless as the `memory` user (uid
982, subuid/subgid range 200000-265535). The first switch from the old rootful
layout must take a fresh export, stop all four units, and hand the graph to
`memory` before activation:

```sh
sudo systemctl start memory-export.service       # known-good pre-migration copy
sudo systemctl stop memory-mcp memory-graphiti-mcp memory-llm-proxy memory-falkordb
sudo chown -R memory:memory /var/lib/memory/falkordb
just switch smortress
ss -ltnp 'sport = :6379'                         # must be 127.0.0.1
sudo -u memory XDG_RUNTIME_DIR=/run/user/982 podman ps
sudo podman ps -a                                # stale rootful containers?
memory status                                    # graph: ok
redis-cli -h 127.0.0.1 -p 6379 DBSIZE            # compare with the export
sudo systemctl start memory-export.service       # exercise the rootless export path
journalctl -u memory-export.service -n 20 --no-pager
```

If a stale container is still holding `127.0.0.1:6379`, remove it from the
store that owns it: `sudo podman rm -f memory-falkordb memory-graphiti-mcp`
or the same `podman rm` as the `memory` user. The rootless image store lives
under `/var/lib/memory/.local/share/containers`; do not add it to backups. After
`memory restore`, the graph directory and snapshot are owned by `memory`,
matching the rootless container. The first switch also pulls both images into
the rootless store; after verification, `sudo podman system prune -a` reclaims
the old rootful copies.

To roll back, stop the four units, switch to the pre-T5 generation (or a
checkout before these commits), `sudo chown -R root:root
/var/lib/memory/falkordb`, and start the units. The rootless store can remain;
only the graph ownership has to return to root.

Graphiti extracts through `memory-llm-proxy` on `127.0.0.1:8082`, which is
Memory's single egress point to Neuralwatt (`api.neuralwatt.com`). The gateway
holds the account key — read from the `neuralwatt-api-key` sops secret through a
systemd credential, never from the environment or the Nix store — injects
`Authorization: Bearer …` to the upstream request (Graphiti's required
`api_key: "none"` placeholder is replaced; a real client-supplied token is
forwarded untouched), and adds
`reasoning_effort: "none"` to chat completions. A reasoning model otherwise
spends its whole token budget thinking and returns empty content, which
Graphiti drops. Graphiti itself runs with `api_key: "none"`.

Episode text goes to Neuralwatt by design; the work-group refusal runs before
any write, so employer content never reaches it. Rotating the key is: update the
sops secret and rebuild — `sops.secrets.neuralwatt-api-key` restarts
the gateway, which reads the credential once at start. A **missing** credential
makes `LoadCredential` fail, so the gateway never starts and the wrapper's
`preStart` (which waits on the gateway) fails with it: reads stop too. An
**empty** credential lets the unit start; every proxied request then returns
503 `configuration_error` while `/health` still answers. A real client-supplied
token is forwarded untouched only when the gateway has a key — without one the
503 is returned before headers are inspected.

The listener is loopback-only and never tunneled, but it is **unauthenticated by
design**: any local process that can reach `127.0.0.1:8082` can spend the
Neuralwatt account through it. Treat the host's user boundary as the billing
boundary. Its `/health` only proves the gateway process is alive; check upstream
access through the proxied `/v1/models`. Request bodies over 10 MB are rejected,
and an upstream read stall is a 504.

The tier math is three concurrent upstream slots: two for memory
(`MEMORY_UPSTREAM_CONCURRENCY=2`, mirrored by Graphiti's
`SEMAPHORE_LIMIT=2`) and one left for Maki's own chat on the same key. The
gateway's permit is held for the whole upstream request, streamed body
included, so it — not Graphiti's semaphore — is the real ceiling, and
oversubscribing only trades throughput for 429s: four in-flight episodes once
earned 944 429s out of 2,270 requests in 20 minutes while a 1,382-episode
backfill starved. A 429 or 503 is a rejection (the request never ran), so the
gateway retries those two — `MEMORY_UPSTREAM_RETRIES=6` attempts, honouring
`Retry-After` (seconds or HTTP-date, capped at 60 s) and otherwise backing off
exponentially with jitter — and returns the upstream 429/503 unchanged once
attempts run out. Nothing else is retried, and nothing is retried after a
response body has started. Because a queue that large drains over hours, the
wrapper's `MEMORY_RECONCILE_GRACE` is 12 hours: a shorter grace marked
still-queued writes failed and resubmitted them as duplicates. If 429s appear
again, lower `MEMORY_UPSTREAM_CONCURRENCY` (and `SEMAPHORE_LIMIT` with it)
before anything else.

A gateway outage is not a submission error. Graphiti answers `add_memory` with
200 and extracts from an in-memory queue, so a dead gateway leaves a `pending`
row with no episode in the graph (`Failed to process episode … Connection
error` in `journalctl -u memory-graphiti-mcp`) and the wrapper never prints its
"submission was deferred" line; the registry row is the only copy. The grace
above bounds when the reconciler replays it, so a drill needs a runtime
override — `MEMORY_RECONCILE_GRACE=300` in
`/run/systemd/system/memory-mcp.service.d/`, `daemon-reload`, restart — then the
first pass past the grace resubmits the content and the row goes `active` once
the episode is verified. Drilled 2026-10-23 with the gateway stopped: the write
stayed `pending` with zero graph episodes, replayed into exactly one episode
~20 s after the override restart, was searchable, and a repeat write of the same
content reported the existing uuid instead of queueing a second extraction.

Embeddings stay local by default: bge-m3 on `llama-cpp-embed` (`127.0.0.1:8183`,
1024 dimensions). `memory.embedder = "neuralwatt"` sends them through the same
gateway to `qwen3-embedding-8b` (4096 dimensions); the model is preview-only and
this account currently gets a 404, so the local service stays deployed either
way and flipping the switch means re-embedding the corpus at a new width.
`qwen3-embedding-8b` prefers an `Instruct: …` / `Query:` prefix on queries;
graphiti-core's OpenAI embedder sends the same text for queries and passages, so
expect a small retrieval penalty.

Personal machines run `cloudflared-memory`, which forwards loopback
`ports.memoryMcp` and injects the Access service token. Maki's generated
`~/.config/maki/mcp.toml` starts `memory-mcp-shim` (server `graphiti`) with
`MEMORY_MCP_URL` and the work markers from `config.user.work` in its
environment; the shim derives the project group from Maki's cwd and forwards to
the wrapper. The same package installs the `memory` CLI, and the personal
profile exports `MEMORY_PERSONAL_OWNER` from `config.user.githubUser` for its
ingest defaults.

Maki reads `mcp.toml` once at startup, and the shim derives the group once when
Maki starts it. Restart Maki after changing `mcp.toml` and after moving to a
different repository: `/cd` does not restart stdio children, so the group stays
fixed until Maki restarts.

The wrapper's typed registry (`registry.sqlite`, including the audit table)
lives in `/var/lib/memory`, owned by the `memory` system user (the FalkorDB
subdirectory is owned by `memory` as well, so rootless podman can write it).
The database carries a `PRAGMA user_version`
schema version. A database one version behind is migrated in place on open
(`ALTER`/backfill statements in one transaction); an unversioned one, or one
newer than the code, is refused rather than guessed at. Restoring an export
taken before a schema bump is therefore fine: it is installed as-is and
migrated the next time the wrapper starts.

`created_at` is when the memory was written; `queued_at` is when it last
entered the pending queue (a replay sets it again, a repeat write keeps the
original `created_at`). The reconciler's grace window, the stale-write window,
the presence bound and `pending()` order read `queued_at`, so a replay starts
with a fresh grace instead of inheriting a months-old one.

**Backup.** The registry is the system of record, so its snapshot *is* the
memory backup: it holds every episode's normalized content and typed
provenance. The graph is a derived index: it is rebuilt only by re-ingesting
the corpus into a wiped store (`just memory-rebuild`).
`memory-export.timer` runs `memory-export.service` daily (00:00 plus up to an
hour of randomized delay, `Persistent=true`, as root so it can stop/start the
services and read the graph directory) and writes one timestamped directory under
`/var/lib/data/memory-export` (mode 0700, root):

- `registry.sqlite` — a consistent copy taken with SQLite's online backup API,
  so the wrapper keeps writing under WAL while it is copied;
- `episodes.jsonl` — every episode with typed provenance (group, uuid,
  content_hash, kind, origin, origin_ref, actor, cwd, tags, valid_at,
  created_at, queued_at, status, graphiti_uuid, promotion and tombstone
  fields) *and* its
  content, so memory is readable even without SQLite;
- `manifest.json` — creation time, `PRAGMA user_version`, per-status counts, and
  the sha256 of each file;
- `graph-<timestamp>.rdb` — the FalkorDB snapshot, when `BGSAVE` finished in
  time. The exporter issues one `BGSAVE` per run and polls `INFO persistence`,
  accepting `dump.rdb` only once the server's `rdb_last_save_time` has advanced
  past the value it read before the save; it never touches the AOF. A missing
  or failed graph snapshot is recorded in the manifest (`graph: null` plus
  `graph_error`) and the registry export still stands, but the command exits
  non-zero so the failed timer run is visible (and alerts, when
  `alerting.enable` is on).

Seven directories are kept; retention only deletes names that are export
timestamps *and* whose `manifest.json` reads, so a partial export (a crashed or
still-running run) is left for the operator rather than counted as one of the
kept snapshots, and the directory a run just wrote is never a prune candidate.
Inspect a run with `journalctl -u memory-export.service`. Take one immediately
with `just memory-export`. An export refuses to run while a restore holds the
lock described below.

**Restore drill.** `sudo memory restore <export-dir>` verifies every manifest
checksum *first*, refuses a registry schema other than the installed code's
(a newer one this code cannot read; an older one the wrapper will not open),
then stops `memory-mcp`, `memory-graphiti-mcp`, `memory-llm-proxy`, and
`memory-falkordb`. The graph store stops too: a running FalkorDB rewrites its
AOF, which would resurrect the data the restore is replacing. The live
`registry.sqlite` and its `-wal`/`-shm` are copied to
`registry.sqlite.pre-restore-<timestamp>`, the export's registry is installed
with one atomic rename, and only then are the replaced database's sidecars
dropped. Ownership (`memory:memory`) is settled on the staged copy *before* the
rename, so a failed `chown` leaves the previous registry in place, exits
non-zero, and names the parked copy. Delete the `*.pre-restore-*` registry files
once the restore checks out.

The graph is handled after the registry:

- the matching `graph-<timestamp>.rdb` is restored only when its timestamp
  equals the registry snapshot's. FalkorDB runs with `appendonly yes` and Redis
  loads the AOF in preference to the RDB, so the restore renames the existing
  `appendonlydir` to `appendonlydir.pre-restore-<timestamp>` — the old AOF is
  kept, never deleted, and otherwise the restored snapshot would be silently
  ignored. It then restarts `memory-falkordb`, because the RDB is only read at
  startup, and reports `graph: restored` only after that restart. Delete the
  parked `appendonlydir.pre-restore-*` once `GRAPH.LIST` and a search confirm
  the graph is the restored one;
- otherwise it refuses the graph, restores the registry alone, and tells you to
  restore an export whose graph snapshot matches, or to rebuild **both** stores.
  A restored registry does not rebuild with `memory-ingest`: it skips rows that
  already succeeded, so re-ingesting an `active` corpus into an empty graph
  extracts nothing. `just memory-reindex --all` is the replay path
  (`memory reindex`): it reads every episode content for a group in one query,
  requeues the active rows with no matching episode, and resubmits that slice
  immediately, so extraction starts now rather than after the reconcile grace.
  It is operator-only, defaults to the caller's group (`--all` for every group),
  handles a bounded slice per call and is safe to repeat — a row is only
  requeued when its episode is absent, and requeueing restarts its queue clock
  so the reconciler waits the grace window for the extraction instead of
  retrying it into `failed`. A group that looks almost entirely missing while
  its graph is not empty is refused unless `--force` is passed, because that
  usually means a wrong graph or a registry from another host. `just memory-rebuild` wipes the FalkorDB data *and* the
  registry, and only then does `just memory-ingest` rebuild anything
  (re-extraction of `active` rows is tracked in #219).

`--dry-run` verifies and prints the plan without stopping or writing anything;
`--no-stop` is accepted only together with `--dry-run`, because a real restore
always stops the services (swapping files under a running store is how a restore
corrupts itself); `--start` also starts `memory-llm-proxy`,
`memory-graphiti-mcp`, and `memory-mcp` after the graph restart; `--owner
user:group` sets the restored registry's owner (default `memory:memory`, an
empty value skips it). A restore writes `<state>/.restore-in-progress` for its
duration, and `memory export` refuses to run while it exists; a failed restore
leaves it in place, so remove it once the state is reconciled. The subcommand is
`memory restore` next to `memory export` — not `memory export restore` — and the
CLI is in the system profile on any host with `memory.enable`, so sudo finds it.
`just memory-restore <dir>` wraps it.

The drill the check suite runs (`tests/memory_export_restore.sh`) is the same
procedure against temp directories: a live WAL registry exports consistently, a
tampered file and a newer schema are refused, retention prunes only its own
complete directories, a mismatched graph snapshot is rejected in favour of the
rebuild path, the stop set reaches `memory-falkordb` and the graph restore
restarts it, a failed ownership step leaves the previous registry in place, and
an export refuses to run while the restore lock exists. It needs no root, no
FalkorDB, and no network.

**Offsite.** `/var/lib/data/memory-export` is inside the restic source tree, so
it lands in both repos (R2 and the local encrypted disk) with the rest of the
durable tree; the registry and its graph snapshot survive losing smortress.
Recovery order is: restore the export, then `memory reindex --all` when the
graph snapshot is missing or older, then confirm with a search.

**Evaluation.** `just memory-eval` runs `modules/features/ai/memory/eval/` against
the live store: 50 labelled queries (semantic, entity, temporal, exact) scored by
recall@5 and MRR for the graph-backed `memory search` against an FTS5/bm25 index
over the same registry rows, then 50 adversarial boundary queries that must
return no entry from a foreign project group. First measured run (2026-10-23,
1,385 episodes): recall@5 0.52 / MRR 0.40 against 0.86 / 0.60 for FTS5, mean
search latency ~4.5 s against ~0.5 ms, and zero foreign-group hits. That run
exposed a structural miss: the wrapper listed every node before any fact, so
while the node list was full no fact could reach the top five. The block now
alternates the two ranked lists; the same 50 queries on the drained corpus
(1,357 rows) measure recall@5 0.66 / MRR 0.42 against 0.78 / 0.55 for FTS5 at
mean 4.1 s against 0.7 ms — 40 of 50 answered somewhere in the block, 33 within
the top five, still zero foreign-group hits. Read both comparisons with care:
the baseline ranks whole episodes while the graph ranks extracted facts and
entities against gold strings that are verbatim corpus text, and a gold token
that merely appears inside an extracted fact sentence counts as a hit for it, so
fact-heavy positions score generously. Community summaries stay off
for now: the misses are single-fact lookups, not the multi-hop thematic questions
summaries help with, and building them costs an extra pass over the corpus.

Search cost on smortress over loopback (same 50 queries): p50 5.2 s, p95 7.9 s,
max 13.1 s, against ~1 ms for FTS5; a returned block is about 1.2–1.4k tokens,
inside the 2k budget the design targets. A Maki client adds tunnel latency on
top of that.



Activate after changing the wrapper, shim, package, LLM proxy, or export
unit:

```sh
just switch smortress
just home-switch smores <personal-host>
```

Verify on smortress:

```sh
systemctl status memory-mcp
curl 127.0.0.1:8182/health
systemctl status memory-llm-proxy
curl 127.0.0.1:8082/v1/models   # proxied to Neuralwatt (needs the credential)
curl 127.0.0.1:8082/health
cd ~/code/<repo> && memory status   # group, registry counts, graph/model readiness
systemctl list-timers 'memory-export*' && journalctl -u memory-export -n 20
```

**Corpus ingest.** The graph already holds episodes from earlier runs, but the
registry starts empty: the first ingest after this deploy sees an **empty
registry against a populated graph** and re-extracts the whole corpus,
duplicating episodes the graph already holds. That is expected and bounded
(one hosted extraction call per episode; the new rows become `active` when
their extraction lands). Reconciling the two stores means wiping both of them
(`just memory-rebuild`) and re-ingesting; making `memory-ingest` re-extract
already-`active` rows is tracked in #219. Deploy the gateway before ingesting: until
`just switch smortress` runs, Graphiti still extracts through the old route and
drops episodes. Then, on smortress:

```sh
systemctl status memory-llm-proxy
curl 127.0.0.1:8082/v1/models        # Neuralwatt answers through the gateway
redis-cli -p 6379 GRAPH.LIST         # group graphs (read-only peek)
memory ingest all --dry-run          # plan only; writes nothing
memory ingest all --limit 5 --dry-run
memory ingest all --limit 5          # small live sample, then the full run
```

`memory ingest all` (or `just memory-ingest` for the full corpus) reads the sdlc
issue list through `gh`, the markdown files under `~/Documents` (recursively),
and the personal clones in `~/code/github.com/<owner>` plus remote READMEs. Run
it on smortress, where the corpus lives and the wrapper's loopback is reachable;
it never talks to Graphiti or FalkorDB directly. Every source runs independently
under `all`; a source that cannot be read is reported in `source_errors` and in
`failures` (with `source_id: "*"`) instead of aborting the others.

Each run writes `~/.local/state/memory/ingest-<timestamp>.json` (build/lookup/
submit counts, failures, and timings) and nothing else: the report is never read
back. To resume, run the same command again. The client asks the wrapper's
`/internal/lookup` which content hashes already exist:

- `active` and `pending` rows are skipped. A source that moved to another group
  looks missing there and is submitted to the new group.
- `failed` rows are resubmitted, which resets their attempts. Tombstoned rows are
  left alone until the content is deliberately written again, and the
  reconciler invalidates any graph episode their extraction produced after the
  tombstone.
- Missing episodes are submitted through `/internal/episodes` with explicit
  `kind` and `valid_at`; the wrapper records them as pending and its reconciler
  resolves them. A retry is bounded and never overlaps an in-flight submission.

**Maki sessions.** `memory ingest sessions` (and `memory ingest all`, which
includes the session sample by default) reads Maki's JSONL transcripts from
`$MAKI_SESSIONS_DIR`, else `$XDG_STATE_HOME/maki/sessions`, else
`~/.local/share/maki/sessions` and `~/.maki/sessions`, and passes
`--sessions-dir`/`--session-limit` to override either. The sample is the 50 most
recently modified session files; each one is bounded to the first and last
messages within a 24k-character transcript, so a 74 MB session cannot exhaust
the token budget. Each session is summarized by `deepseek-v4.1-flash`
(`MEMORY_SUMMARY_MODEL` overrides) at temperature 0 with a JSON-object response
asking for a prose summary plus explicit decisions, constraints, errors, and
user preferences; every one of those becomes its own episode, so all of a
session's episodes share `origin=session` and `origin_ref=<session id>`.
Session text is personal and leaves this machine for summarization through the
loopback gateway; only the summary and the extracted items are stored, and a
session whose cwd is a work checkout is refused before any request is made. A
session whose cwd does not exist here is refused too, because its work markers
cannot be checked: a cross-machine session must be ingested where its cwd
exists. Only the cwd's path components are checked for employer markers; text
inside a personal checkout is not scanned for employer content.

An unchanged session is not re-summarized. A disposable cache at
`$MEMORY_SESSIONS_CACHE` (default `~/.local/state/memory/sessions.json`) is
keyed by session id plus the bounded transcript's SHA-256, so a repeated run
reuses the earlier summary and cannot paraphrase the same session into a second
episode; a changed transcript is summarized again. The cache is not a ledger:
the registry still decides duplicates, and the file can be deleted at any time.
`--limit` bounds episodes per source but not sessions; `--session-limit` bounds
the sample, so `memory ingest all` spends about that many summary calls.

The summary call runs from the operator's shell, not from a unit, so it reaches
the gateway at `MEMORY_LLM_URL` (default `http://127.0.0.1:8082`) and needs no
Neuralwatt key. Per-session wall time, prompt/completion `usage` tokens, and an
estimated cost live under `sessions` in the run report; the prices are
`MEMORY_SUMMARY_PRICE_IN`/`MEMORY_SUMMARY_PRICE_OUT` (USD per million, default
0.15/0.60), and the summary line is printed on stderr. A missing `usage` block
reports `cost unknown` rather than $0, and retries accumulate tokens because
every paid attempt counts. `--session-concurrency`
(default 3) bounds simultaneous summary calls, and `--dry-run` parses and
estimates tokens without calling the model; a live run prints the sampled count
and its token/cost estimate to stderr before the first call.

Extraction is one hosted chat call per episode, so a full corpus takes hours.
`--concurrency` (default 4) bounds simultaneous submissions; the wrapper's
reconciler verifies them in the background. For a long run, start it in a
transient user unit:

```sh
systemd-run --user --unit memory-ingest --collect --setenv=MEMORY_MCP_URL=http://127.0.0.1:8182/mcp \
  -- memory ingest all
systemctl --user status memory-ingest
journalctl --user -u memory-ingest -f
```

The tunnel ingress and Access application are unchanged by this step. For a
first deployment, apply the Memory Access application **before** rebuilding
smortress:

```sh
sudo nix run .#cloudflare-apply
just switch smortress
```

The wildcard CNAME already exists, so the rebuild adds the ingress; applying
tofu first means Access is in place the moment the hostname starts routing.
The email policy is inert for this TCP endpoint (service tokens only).

### Rebuilding the store

The registry is authoritative and the graph is derived, so a rebuild is: stop
the memory services, delete the graph data and the registry, start them again,
and re-ingest. It is the only destructive memory operation, and it also changes
the vector width when `memory.embedder` changes.

```sh
just switch smortress     # applies the embedder choice (qwen3, 4096-d)
just memory-rebuild       # stop, wipe, start (sudo)
just memory-ingest        # re-extract the corpus; hours, run in a user unit
```

`just memory-rebuild` removes `/var/lib/memory/falkordb/*`, `registry.sqlite*`,
`index.sqlite*`, `audit.jsonl` and the internal token (regenerated at start).
The first `memory ingest all` then treats every planned hash as missing and
re-embeds the corpus at the new width. Do not run it while anything else is
writing memory. Since #223 there is an export to fall back on: take one with
`just memory-export` (or restore the newest with `just memory-restore <dir>`)
before wiping, because a rebuild that goes wrong otherwise loses the registry,
which is the system of record.

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
`MEMORY_MCP_DEFAULT_ACTOR=open-webui`); that keeps chat writes in the shared
group and records their own provenance, while Maki and the CLI keep the strict
header contract. `files-mcp` (`http://127.0.0.1:8185/mcp`) needs no token. A
malformed value is silently dropped by Open WebUI, so an empty External Tool
Servers list means the JSON is broken.

**Code interpreter** is Jupyter in the `jupyter` agent-sandbox profile
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

`smortress` logs in with the PIV keys in slot 9a, which `yk-ensure` loads into
`fido2-agent` on first use (or `yk-login` in a terminal). `fido2-agent-load`
loads only the touch-only sudo handles at login. If `ssh smortress` starts
failing after another PIV client ran (`pam_p11` at the greeter, `ykman piv`),
the card session was reset; run `yk-login` again. If that happens daily, fall back to slot 9c with PIN
policy ALWAYS plus the askpass cache (the pre-T1 layout).

## Flake apps

Apps come from `modules/flake/apps.nix`. Run them as `nix run .#<name>`; from
another machine use `github:smores56/nix-config#<name>`.

### bootstrap

<!-- manual-step: app/bootstrap -->

Fresh machine (requires only Nix): clones the repo via ghq, switches
home-manager, writes the committed SSH public keys, logs in GitHub, and on
NixOS applies the system configuration. `bootstrap.sammohr.dev` is not
provisioned by this repo; use the flake app.

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

Upload the printed `.tar.gz` and `.sha256` to a Proton Pass **Note** item named
`nix-config restore bundle — <host>` (Pass encrypts attachments end-to-end),
then remove the local copies (`shred -u` on Linux, `rm -P` on macOS). Keep the
archive and its checksum together, with the `.sha256` named `<archive>.sha256`;
the file holds a bare hash, so renaming both together still works. The restore
refuses to proceed without it. An incomplete backup fails and names the missing
handles; `--allow-incomplete` archives a deliberate partial set. Do not wipe
until the handle count matches the inventory in `modules/lib/yubikey-keys.nix`
(six today).

None of that protects the host key the bundle now carries: it is a plaintext
private SSH key. Reading the Pass item is enough to impersonate `<host>` and to
decrypt every secret that host is a recipient of — no YubiKey, PIN, or touch
involved. The admin age key stays out of the bundle; the host identity does not.

### key-restore

<!-- manual-step: app/key-restore -->

Download the two files from the Proton Pass item. Two modes, in this order:

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
rewrite the Pass item can rewrite the `.sha256` too. The `&<host>` anchor in
`.sops.yaml` is the only authenticity control, and only `--host-key` enforces
it. It does not inspect the touch/PIN flags, which live in the private
file; a flagged credential is still bound to the same token. `--no-verify` skips only the outer checksum; it cannot skip the
committed-key check. Then run `home-manager switch` if bootstrap did not
already write the public keys, and verify with `ssh smortress true` and
`ssh -t smortress sudo true`. The first signature prompts for the PIN once;
`yk-login` remains the terminal fallback when no dialog can be shown.

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
clients that embed it (Proton Pass), and re-run `cloudflare-plan`.

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

### Radicale htpasswd

<!-- manual-step: secret/radicale-htpasswd -->

One bcrypt line from `htpasswd -nB smores`, owner `radicale`, 0400. Rotation:
regenerate, update `secrets/smortress.yaml`, rebuild, and re-add the account in
DAVx5/khal.

### Jupyter token

<!-- manual-step: secret/jupyter-token -->

Random 32 bytes, root-owned 0400, read by the sandboxed Jupyter server and
injected into Open WebUI's environment file. Rotation invalidates running
kernels.

### Memory MCP token

<!-- manual-step: secret/memory-mcp-token -->

Random 32 bytes in `secrets/common.yaml`, user-readable 0400. Presented as
`Authorization: Bearer` by Maki, the memory CLI/shim, and Open WebUI. Rotation
requires restarting `memory-mcp`, Maki, and Open WebUI.

### dav.sammohr.dev

<!-- manual-step: service/smortress/dav -->

Radicale over the tunnel at `https://dav.sammohr.dev/`, public with its own
bcrypt auth; CalDAV clients cannot complete an Access login. The
`dav_rate_limit` WAF ruleset is managed by `nix run .#cloudflare-apply`.

### music.sammohr.dev

<!-- manual-step: service/smortress/navidrome -->

Navidrome at `https://music.sammohr.dev/`, public with its own auth. Create the
first account in the web UI; it becomes the admin.
