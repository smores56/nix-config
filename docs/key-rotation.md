# YubiKey and device rotation

Public keys and certificates live in the repo; private key material never
does. The three YubiKeys (`k1`, `k2`, `k3`) are interchangeable and every
authorized list carries all three. The operator setup script is
`~/dev/setup-yubikey.sh` on `smorespro` (it is not tracked yet); it produces
`~/yubikey-setup/kN/` with the public material and a report.

## Enrollment checklist

For each key:

1. Run `setup-yubikey.sh N` (or `--replace` when re-enrolling), then commit:
   - PIV 9a public key: `modules/nixos/ssh.nix` `authorizedKeys` and
     `modules/features/ssh-keys.nix` `yubikeyIdentities`
   - PIV 9a certificate: `modules/features/fido2.nix` `pivCerts`
   - sudo public key: `modules/nixos/ssh.nix` `sudo_authorized_keys`
   - signing public key: `modules/features/ssh-keys.nix` `yubikeyIdentities`
2. Run `home-manager switch` on `smorespro` and `smortress`, then run
   `yk-login` in a terminal after login.
3. Test `ssh smortress true`, `ssh -t smortress sudo true` (one touch, no PIN),
   and a signed commit on both hosts.
4. Enroll the key in Proton account 2FA and keep the recovery codes offline.
5. Store the PUK in phone Proton Pass and off-site; the PIN is memorized only.
6. Register the PIV and signing keys on GitHub as **signing** keys only.
   Never register either as an authentication key.
7. For `smoreswork`, see the smart-card section below.

## Lost or stolen key

1. Remove the key's three lines from `modules/nixos/ssh.nix`
   (`authorizedKeys` and `sudo_authorized_keys`), its 9a certificate from
   `pivCerts`, and its PIV/signing entries from `ssh-keys.nix`
   (`yubikeyIdentities`).
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

The Mac does not use the Linux `fido2-agent` or the PIN cache. Its SSH host
block uses OpenSC's PC/SC provider, so the PIN is typed on the tty per
connection. Signing on work repos stays on the work software key.

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
   Every key already has a 9d certificate (`9d-kN.crt` in
   `~/yubikey-setup/kN/`); macOS uses 9a for authentication and 9d for the
   keychain/volume. Do not enable FileVault smart-card unlock. Repeat until
   `sc_auth list -u sam` shows all three hashes.
3. After the T1 branch is deployed, test SSH with each key:
   ```sh
   ssh smortress true
   ```
   The Mac uses OpenSC's `PKCS11Provider` and prompts for the PIV PIN on the
   tty; there is no agent or PIN cache on macOS. All three keys should work.
4. `sudo` on smortress from the Mac is the remaining T4 piece: it needs a
   local `ssh-agent` holding the three sudo handles (launchd), which is not in
   the T1 branch. Until T4 lands, use `smorespro` or the console for sudo from
   the work Mac.
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
3. Rotate the Maki personal/work PATs, revoke the old tokens, and re-run
   `sops` deployment.
4. Sign out Proton web sessions and rotate the Proton password if the device
   could read the session.
5. On the phone, use the account console to remote-wipe and remove the device
   from Proton/Cloudflare sessions.
