# YubiKey and device rotation

Public keys and certificates live in the repo; private key material never
does. The three YubiKeys (`k1`, `k2`, `k3`) are interchangeable and every
authorized list carries all three. The operator setup script is
`~/dev/setup-yubikey.sh` on `smorespro` (it is not tracked yet); it produces
`~/yubikey-setup/kN/` with the public material and a report. The script is
included in the Proton Pass restore bundle (below) as data until it moves into
the repo; the report directory is not copied.

The FIDO2 credential *handles* under `~/.config/ssh-sk/kN/{sudo,signing}` are
per-machine files: the private half is on the token, but OpenSSH needs the
handle to use it. A machine wipe loses them, so run `nix run .#key-backup`
before reinstalling and restore with `nix run .#key-restore` afterwards (see
`docs/manual-steps.md`). PIV private keys cannot be exported and are unaffected
by a wipe.

## Enrollment checklist

For each key:

1. Run `setup-yubikey.sh N` (or `--replace` when re-enrolling), then commit
   the PIV 9a public key + certificate, sudo public key, and signing public key
   to `modules/lib/yubikey-keys.nix`. That file is the single source for sshd,
   pam_p11, allowed_signers, and the bundle's integrity check.
2. Run `home-manager switch` on `smorespro` and `smortress`, then run
   `yk-login` in a terminal after login.
3. Test `ssh smortress true`, `ssh -t smortress sudo true` (one touch, no PIN),
   and a signed commit on both hosts.
4. Enroll the key in Proton account 2FA and keep the recovery codes offline.
5. Store the PUK in phone Proton Pass and off-site; the PIN is memorized only.
6. Register the PIV and signing keys on GitHub as **signing** keys only.
   Never register either as an authentication key.
7. For `smoreswork`, see the smart-card section below.
8. On the machine holding the handles, run `nix run .#key-backup` and upload the
   archive and checksum to the Proton Pass restore item (see
   `docs/manual-steps.md`). Repeat after any re-enrollment changes a handle.

## Reinstalling a machine

A wipe does not touch the YubiKeys: PIV private keys are generated on-device and
cannot be exported, and the FIDO2 private half never leaves the token. The only
YubiKey material a wipe destroys is `~/.config/ssh-sk/kN/{sudo,signing}`, the
credential handles OpenSSH must present to the token.

`key-backup` archives the live `/etc/ssh/ssh_host_ed25519_key` — the host's sops
identity — into the bundle, so no separate copy is needed. In the operator
checkout, `nix run .#key-restore -- <bundle> --host-key` writes it to
`secrets/hosts/<host>/` for `install`; that mode fails closed when `.sops.yaml`
has no `&<host>` anchor or the key derives a different recipient. If it is ever
lost, mint a replacement with `nix run .#host-key -- <host>` and re-key
`.sops.yaml`.

1. Before wiping, on that machine: `nix run .#key-backup` (add `--no-host-key`
   on a machine with no host identity of its own, such as `smoreswork`), then
   attach the printed `.tar.gz` and `.sha256` to the Pass restore item and
   remove the local copies (`shred -u` or `rm -P`). The handle count must match
   the inventory in `modules/lib/yubikey-keys.nix` (six today); a missing handle
   is a lost leg. `key-backup` fails on a partial set unless
   `--allow-incomplete` is given.
2. Download the two files from Pass and, in the operator checkout, run
   `nix run .#key-restore -- <bundle>.tar.gz --host-key` to write
   `secrets/hosts/<host>/` before installing.
3. Install and `nix run .#bootstrap`; then restore the handles with
   `nix run .#key-restore -- <bundle>.tar.gz`.
4. `home-manager switch` if needed, `yk-login`, then verify
   `ssh smortress true` and `ssh -t smortress sudo true`.

The admin age key (`~/.config/sops/keys.age`) is deliberately excluded: it is
the root of the secrets tree and stays passphrase-encrypted on both laptops, so
a wiped `smorespro` still leaves `smoreswork`'s copy. PINs and PUKs are never
written to the bundle. The enrollment script is restored as 0600 data; review
it and `chmod +x` before running it.

## Lost or stolen key

1. Remove the key's entries from `modules/lib/yubikey-keys.nix` (its PIV 9a
   public key and certificate, sudo public key, and signing public key). That
   file feeds sshd's `authorized_keys`, `/etc/ssh/sudo_authorized_keys`,
   pam_p11's certificate list, and `allowed_signers`.
2. Run `home-manager switch` on `smorespro` and `smortress`. If the key was
   with a laptop, also revoke that machine's Cloudflare Access service token,
   rotate the Maki PATs, and sign out Proton sessions (see below).
3. Remove the key from Proton account 2FA and enroll the replacement.
4. If the key is recovered, do not re-add it until the PIV and FIDO2 apps have
   been reset and re-enrolled; treat the old credentials as burned.

## Locked PIV PIN

With the PUK from phone Pass:

```sh
ykman piv access unblock-pin
ykman piv access change-pin
```

That restores the PIN without touching the PIV keys. If the PUK is exhausted,
the PIV application must be reset and every PIV credential re-enrolled; the
9a certificate and public key change.

## Locked FIDO2 PIN

```sh
ykman fido info
ykman fido reset
```

`fido reset` destroys **all** FIDO2 credentials on that key, including the
sudo/signing handles and the Proton WebAuthn registration. Re-run
`setup-yubikey.sh N --replace`, re-enroll the key in Proton 2FA, and update
GitHub. The PIV applet and 9a key are independent and are not reset.

## Retry checks

```sh
ykman piv info     # PIN/PUK tries remaining
ykman fido info    # FIDO2 PIN tries remaining
```

`yk-login` refuses to send the PIN below four FIDO2 retries. A wrong cached
PIN is never replayed: `yk-login` verifies the PIN before writing the cache.

## smoreswork (work Mac)

The Mac does not use the Linux `fido2-agent` or the PIN cache for login. Its
SSH host block uses OpenSC's PC/SC provider, so the PIN is typed on the tty
per connection. A launchd agent (`smortress-sudo-agent`) holds only the three
sudo handles and is forwarded to smortress for `pam_rssh`; signing on work
repos stays on the work software key.

1. Insert a key and list identities:
   ```sh
   sc_auth identities
   sc_auth list -u sam
   sc_auth pairing_ui -s status
   ```
   `pairing_ui` must report enabled. If MDM sets `UserPairing=false`, stop
   and record the block; password/Touch ID remains. The certificate-trust
   default is off; if MDM sets `checkCertificateTrust`, self-signed 9a/9d
   certificates may need an exception:
   ```sh
   sudo defaults read /Library/Preferences/com.apple.security.smartcard checkCertificateTrust
   ```
2. Pair the 9a identity for **each** key:
   ```sh
   sc_auth pair -u sam -h <9a hash from sc_auth identities>
   ```
   macOS also wants a 9d certificate for the keychain/volume. If a key does
   not have one, generate it (operator, per key, output path required):
   ```sh
   ykman piv keys generate 9d /tmp/9d-kN.pub --algorithm ECCP256 --pin-policy ONCE
   ykman piv certificates generate 9d /tmp/9d-kN.pub --subject "CN=smores 9d kN" --valid-days 3650
   ```
   macOS uses 9a for authentication and 9d for the keychain/volume. Do not
   enable FileVault smart-card unlock. Repeat until `sc_auth list -u sam`
   shows all three 9a hashes.
3. After the T1 branch is deployed, test SSH with each key:
   ```sh
   ssh smortress true
   ```
   The Mac uses OpenSC's `PKCS11Provider` and prompts for the PIV PIN on the
   tty; there is no login agent or PIN cache on macOS. All three keys should
   work.
4. `sudo` on smortress from the Mac uses the launchd
   `smortress-sudo-agent` (`~/.ssh/sudo-agent.sock`), which loads the three
   `~/.config/ssh-sk/k*/sudo` handles and is forwarded by `Host smortress`.
   The handles must be on the Mac: restore the Pass bundle
   (`nix run .#key-restore -- <bundle>.tar.gz`) or copy them, then restart the
   agent so it re-reads them:
   ```sh
   launchctl kickstart -k gui/$(id -u)/org.nix-community.home.smortress-sudo-agent
   ```
   Test `ssh -t smortress sudo true`: one touch, no PIN. If the agent has no
   handles, sudo falls back to the password. Any local process can ask the
   forwarded agent for a signature and the only signal is the key blinking;
   treat an unexpected touch request as an attack. Verify with:
   ```sh
   SSH_AUTH_SOCK=~/.ssh/sudo-agent.sock ssh-add -l   # three sudo keys
   ```
5. Do not enable FileVault smart-card unlock. Verify:
   ```sh
   fdesetup status
   sudo fdesetup list
   ```
6. Proton/1Password isolation: create a dedicated Proton browser profile,
   remove the 1Password extension there, enable Proton Pass with its extra
   password and biometrics, and delete any Proton login item from 1Password.
7. Phone: 8+ digit passcode, biometrics, OS app lock and biometrics for Proton
   Pass, 1-minute auto-lock, extra password, no 6-digit app PIN, remote wipe
   verified.

## Stolen laptop or phone

1. Revoke the machine's Cloudflare Access service token and rebuild its
   `cloudflared` credentials.
2. If a YubiKey was with the device, remove its three public entries as in
   “Lost or stolen key” and remove it from Proton 2FA.
3. `smoreswork` only: unpair the smart card (`sc_auth unpair -u sam -h <hash>`
   for each hash in `sc_auth list -u sam`), remove the machine's
   `smortress-sudo-agent` socket, and have the employer rotate the FileVault
   recovery key and institutional recovery material — the repo does not own
   either.
4. Rotate the Maki personal/work PATs, revoke the old tokens, and re-run
   `sops` deployment.
5. Sign out Proton web sessions and rotate the Proton password if the device
   could read the session.
6. On the phone, use the account console to remote-wipe and remove the device
   from Proton/Cloudflare sessions.
