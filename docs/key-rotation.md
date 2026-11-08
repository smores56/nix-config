# YubiKey and device rotation

Public keys and certificates live in the repo; private key material never
does. The three YubiKeys (`k1`, `k2`, `k3`) are interchangeable and every
authorized list carries all three. The operator setup script is `~/dev/setup-yubikey.sh` on `smorespro`; it is
untracked and lives only in `~/dev`. It produces `~/yubikey-setup/kN/` with the
public material and a report. The Bitwarden restore bundle (below) carries the
script as data; the report directory is not copied.

The FIDO2 credential *handles* under `~/.config/ssh-sk/kN/sudo` are
per-machine files: the private half is on the token, but OpenSSH needs the
handle to use it. A machine wipe loses them, so run `nix run .#key-backup`
before reinstalling and restore with `nix run .#key-restore` afterwards (see
`docs/manual-steps.md`). PIV private keys cannot be exported and are unaffected
by a wipe.

## Enrollment checklist

For each key:

1. Run `setup-yubikey.sh N` (or `--replace` when re-enrolling), then commit
   the PIV 9a public key + certificate and the sudo public key to
   `modules/lib/yubikey-keys.nix`. That file is the single source for sshd,
   pam_p11, the sudo authorized keys, and the bundle's integrity check. The
   YubiKeys do not sign commits (the sops keys in
   `modules/lib/signing-keys.nix` do): if the script also creates an
   `ssh:sign-kN` credential, nothing uses it; delete it as below.
2. Run `home-manager switch` on both laptops, then log out of each (that clears
   the PIN cache). Changing a PIN leaves the retry counter at its maximum, so a
   stale cache still looks fresh and would cost one rejected PIV login. The
   next SSH to smortress prompts once.
3. Test `ssh smortress true` and `ssh -t smortress sudo true` (one touch, no
   PIN) on both hosts.
4. Enroll the key as WebAuthn 2FA on the Bitwarden account and keep the recovery
   code offline.
5. Store the PUK in Bitwarden and off-site; the PIN is memorized only.
6. Register nothing on GitHub: git uses each account's PAT and sops signing
   key, never a YubiKey.
7. For `smoreswork`, see the smart-card section below.
8. On the machine holding the handles, run `nix run .#key-backup` and upload the
   archive and checksum to the Bitwarden restore item (see
   `docs/manual-steps.md`). Repeat after any re-enrollment changes a handle.

## Reinstalling a machine

A wipe does not touch the YubiKeys: PIV private keys are generated on-device and
cannot be exported, and the FIDO2 private half never leaves the token. The only
YubiKey material a wipe destroys is `~/.config/ssh-sk/kN/sudo`, the
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
   attach the printed `.tar.gz` and `.sha256` to the Bitwarden restore item and
   remove the local copies (`shred -u` or `rm -P`). The handle count must match
   the inventory in `modules/lib/yubikey-keys.nix` (six today); a missing handle
   is a lost leg. `key-backup` fails on a partial set unless
   `--allow-incomplete` is given.
2. Download the two files from Bitwarden and, in the operator checkout, run
   `nix run .#key-restore -- <bundle>.tar.gz --host-key` to write
   `secrets/hosts/<host>/` before installing.
3. Install and `nix run .#bootstrap`; then restore the handles with
   `nix run .#key-restore -- <bundle>.tar.gz`.
4. `home-manager switch` if needed, then verify `ssh smortress true` and
   `ssh -t smortress sudo true` (the first use prompts for the PIN once).

The admin age key (`~/.config/sops/keys.age`) is deliberately excluded: it is
the root of the secrets tree and stays passphrase-encrypted on every machine, so
a wiped smorespro still leaves the copies on the others. PINs and PUKs are never
written to the bundle. The enrollment script is restored as 0600 data; review
it and `chmod +x` before running it.

## Lost or stolen key

Revoking means reaching the host, and losing the key does not lock that out:
`ssh smortress` falls back to the `smores` account password when no YubiKey is
inserted (`docs/manual-steps.md`, "smortress/ssh"). Use it for the steps below
until the replacement is enrolled.

1. Remove the key's entries from `modules/lib/yubikey-keys.nix` (its PIV 9a
   public key and certificate, and its sudo public key). That file feeds
   sshd's `authorized_keys`, `/etc/ssh/sudo_authorized_keys`, and pam_p11's
   certificate list.
2. Run `home-manager switch` on `smorespro` and `smortress`. If the key was
   with a laptop, also revoke that machine's Cloudflare Access service token,
   rotate the Maki PATs, and sign out Bitwarden sessions (see below).
3. Remove the key from Bitwarden's 2FA and enroll the replacement.
4. If the key is recovered, do not re-add it until the PIV and FIDO2 apps have
   been reset and re-enrolled; treat the old credentials as burned.

## Locked PIV PIN

With the PUK from Bitwarden:

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
sudo handles and the Bitwarden WebAuthn registration. Re-run
`setup-yubikey.sh N --replace` and re-enroll the key in Bitwarden's 2FA. The PIV applet and 9a key are independent and are not reset.

## Retry checks

```sh
ykman piv info     # PIN/PUK tries remaining
ykman fido info    # FIDO2 PIN tries remaining
```

`piv-ensure` refuses to send the PIN below two PIV retries and caches it only
after the card accepted it. It replays the cache only while the card's serial
matches and its counter is full, so a spent try or a swapped key re-prompts; a
PIN change keeps both, so log out as step 2 says.

## smoreswork (work Mac)

`sam` is not an administrator on this Mac. `sudo` prompts for the smartcard PIN
and then fails at `sam is not in the sudoers file`; do not use it.
`sc_auth pair`/`unpair` and any `sudo` command below are IT/MDM actions.
Only k2 is paired; use k2 for login, or ask IT to pair k1/k3.

Same design as Linux: the launchd `piv-agent` (`~/.ssh/piv-agent.sock`, never
forwarded) holds the OpenSC provider, `piv-ensure` loads it with one masked
dialog per login session, and `sudo-agent` holds only the three sudo handles
and is forwarded to smortress for `pam_rssh`. The PIN cache lives in the
per-user temp dir, which `piv-pin-wipe` empties at login. Commits sign with the
sops keys, not a YubiKey.

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
   defaults read /Library/Preferences/com.apple.security.smartcard checkCertificateTrust
   ```
2. Ask IT to pair the 9a identity for **each** key:
   ```sh
   sc_auth pair -u sam -h <9a hash from sc_auth identities>
   ```
   `sam` cannot run this; pairing requires administrator credentials.
   macOS also wants a 9d certificate for the keychain/volume. If a key does
   not have one, generate it (operator, per key, output path required):
   ```sh
   ykman piv keys generate 9d /tmp/9d-kN.pub --algorithm ECCP256 --pin-policy ONCE
   ykman piv certificates generate 9d /tmp/9d-kN.pub --subject "CN=smores 9d kN" --valid-days 3650
   ```
   macOS uses 9a for authentication and 9d for the keychain/volume. Do not
   enable FileVault smart-card unlock. Ask IT to repeat until `sc_auth list -u sam`
   shows all three 9a hashes.
3. Test SSH with each key:
   ```sh
   ssh smortress true
   ```
   The first connection after inserting a key opens the PIV PIN dialog;
   repeat connections do not. Swapping keys re-prompts. All three keys should
   work.
4. `sudo` on smortress from the Mac uses the launchd
   `sudo-agent` (`~/.ssh/sudo-agent.sock`), which loads the three
   `~/.config/ssh-sk/k*/sudo` handles and is forwarded by `Host smortress`.
   The handles must be on the Mac: restore the Bitwarden bundle
   (`nix run .#key-restore -- <bundle>.tar.gz`) or copy them, then restart the
   agent so it re-reads them:
   ```sh
   launchctl kickstart -k gui/$(id -u)/org.nix-community.home.sudo-agent
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
   # ask IT/MDM to run: sudo fdesetup list
   ```
6. Bitwarden/1Password isolation: keep Bitwarden in its own browser profile with
   no 1Password extension, keep its vault timeout short with biometrics on, and
   delete any work login item from Bitwarden.
7. Phone: 8+ digit passcode, biometrics, OS app lock and biometrics for
   Bitwarden, short vault timeout, no 6-digit app PIN, remote wipe verified.

## Secret rotation

Every value below is a sops secret. Mint the replacement upstream, replace it in
the right file, commit, deploy, prove the new value, then revoke the old one.
The per-secret instructions are in `docs/manual-steps.md` ("Rotation
checklist"); what follows is custody and the parts a rebuild does not do for
you. Bitwarden holds the operator's copies; no host keeps one.

### GitHub signing keys

One key per GitHub account: `github-personal-signing-key` in
`secrets/common.yaml` (every host) and `github-work-signing-key` in
`secrets/smoreswork.yaml` (the work Mac only). The public halves are committed
in `modules/lib/signing-keys.nix`, which is what writes
`~/.config/ssh/allowed_signers`, names the private half in `user.signingkey`,
and lets smortress trust it for the forced `agent-ssh` login (which lands in
smortress's agent VM). Per account:

1. Mint a new pair: `ssh-keygen -t ed25519 -N '' -C
   github-personal-signing-key -f /tmp/signing`.
2. `sops secrets/common.yaml` (or `secrets/smoreswork.yaml`), replace the value
   with the private half, commit, then `sops updatekeys` that file so every
   recipient still wraps the data key.
3. Replace the account's entry in `modules/lib/signing-keys.nix` with the new
   `.pub` line, commit, and `home-manager switch` on each host (`ssh-pub-keys`
   rewrites `allowed_signers` without a full switch).
4. Register the public half as a **signing** key on the right account (Settings
   → SSH and GPG keys → New SSH key); the work key never goes on the personal
   account.
5. Prove it: `git commit --allow-empty -m test`, then `git log -1
   --format='%G?'` must print `G`.
6. Delete the old key on GitHub and shred `/tmp/signing`.

No `allowed_signers` entry carries a `valid-before` field, so removing the old
public half un-trusts the old key for every signature it ever made, earlier
commits included; GitHub keeps the verification it recorded at push time, and
there is nothing else to prune. No YubiKey is involved: these keys are files.

### restic repository password

One password opens both repos (`secrets/smortress.yaml`, `restic-password`), so
a bare sops edit locks restic out of its own history. Rotate through restic's key
management instead:

```sh
sudo restic-r2 key list              # note the current key id
sudo restic-r2 key add               # prompts for the new password twice
sops secrets/smortress.yaml          # replace restic-password
sudo nixos-rebuild switch            # redeploys /run/secrets/restic-password
sudo restic-r2 snapshots             # proves the new password
sudo restic-r2 key remove <old-id>   # only after the proof
```

Repeat for `restic-local`, or skip the key work there and re-seed: the local
repo is derived, so stopping its timer, emptying `/var/backup/restic` and letting
`initialize = true` recreate it produces the same result. Update the Bitwarden
item and the offline paper copy in the same session; losing all three copies
loses the backups.

### R2 access key pair

Cloudflare → R2 → Manage R2 API Tokens: create a token scoped to the
`restic-backup` bucket with Object Read & Write. Replace `r2-access-key-id` and
`r2-secret-access-key` in `secrets/smortress.yaml`, rebuild, and prove the swap
with `sudo restic-r2 snapshots`; the restic unit reads them through the
sops-rendered `restic-r2.env`. Delete the old token only after that run. R2
cannot rotate a token in place, so there are always two live credentials during
the swap — both write the same bucket, which is harmless for one restic client.

### Memory MCP token

`memory-mcp-token` in `secrets/common.yaml`, user-readable, presented as
`Authorization: Bearer` by Maki's shim, the `memory` CLI, and Open WebUI. Mint
`openssl rand -base64 32`, replace the value, then rebuild smortress (the
secret's `restartUnits` restarts `memory-mcp`) and every laptop. Open WebUI
embeds the token in its tool-server configuration and is not in `restartUnits`,
so restart it by hand; Maki caches it per session, so it needs a restart too.

### Jupyter token

A random 32-byte value in `secrets/smortress.yaml` (`jupyter-token`), 0400, read
by the Jupyter unit through `JUPYTER_TOKEN_FILE` and injected into Open WebUI's
environment file. Replace it, rebuild, and restart `jupyter` and `open-webui`;
running kernels do not survive, which is the point of rotating it.

### cloudflared credentials

The tunnel JSON (`AccountTag`, `TunnelID`, `TunnelSecret`) in
`secrets/smortress.yaml` (`cloudflared-credentials`). cloudflared has no
secret-rotation subcommand, so this is a tunnel replacement, run from the
console because the tunnel is the only path to the host: create the tunnel, paste
the JSON, re-point DNS with `cloudflare-plan`/`cloudflare-apply` (`TunnelID`
changed), restart `cloudflared-tunnel-smortress`, confirm SSH and the public
hostnames, then delete the old tunnel. The step-by-step is under "Rotation
checklist → cloudflared-credentials" in `docs/manual-steps.md`.

### Cloudflare Pages token (GitHub Actions)

The recovery workflow (`.github/workflows/recovery.yml`) publishes
`recovery/dist` to the `recovery` Pages project with a token stored as the
repository secret `CLOUDFLARE_API_TOKEN`. Mint it in the Cloudflare console with
exactly one permission, **Account → Cloudflare Pages → Edit**, and no zone access:
the workflow uploads files and nothing else. Rotate by creating the new token,
updating the GitHub secret, running the workflow once, then revoking the old
token. The Pages project itself, its custom domain and the `recovery` DNS record
are tofu resources, applied with `nix run .#cloudflare-apply`. Cloudflare validates
a Pages custom domain asynchronously: the first apply can leave it pending, so run
the app again and check `recovery.sammohr.dev` before printing any letter.

## Stolen laptop or phone

1. Revoke the machine's Cloudflare Access service token and rebuild its
   `cloudflared` credentials.
2. If a YubiKey was with the device, remove its three public entries as in
   “Lost or stolen key” and remove it from Bitwarden's 2FA.
3. `smoreswork` only: ask IT/MDM to unpair the smart card (`sc_auth unpair -u sam -h <hash>`
   for each hash in `sc_auth list -u sam`), remove the machine's
   `sudo-agent` socket, and have the employer rotate the FileVault
   recovery key and institutional recovery material — the repo does not own
   either.
4. Rotate the Maki personal/work PATs, revoke the old tokens, and re-run
   `sops` deployment.
5. Sign out every Bitwarden session and change the Bitwarden master password if
   the device could read the vault.
6. On the phone, use the account console to remote-wipe and remove the device
   from Bitwarden and Cloudflare sessions.
