# Kanbei phone pipeline (SMS, MMS, calls, contacts, health)

Part of the Kanbei split (`docs/kanbei-split.md`). The phone is the only source that is
not an ingest VM: it has no vsock channel and no credentials for anything else. It writes
two apps' daily exports into one Syncthing folder, the phone shares that folder to the
host **receive-encrypted**, and the kanbei guest decrypts it in-VM.

```
phone (trusted Syncthing peer)                     smortress                         kanbei guest
  SMS Import/Export  ─┐                       /var/lib/data/phone-untrusted     /var/lib/kanbei/phone
  healthconnect fork ─┴─> Syncthing folder ──>  (ciphertext, 0700 vault)  ──ro──>  (plaintext, LUKS)
      /Sync/phone                                 receiveencrypted             │
      sms/ health/ contacts/                      Syncthing as `vault`         ├─> manifest.json
                                                                                ├─> sms/ contacts/ health/
   folder password ──────── sops ──> /run/secrets/phone-folder-password ────────┤
                                    (host, 0400)                                 ├─> phone-state/batches/
                                    └─ ro share ──> /run/kanbei-secrets ────────┘   (batch envelopes)
                                                    → staged 0400 in LUKS
```

The host has no password and never sees plaintext. The phone's password and the folder id
are all that a compromised host would still need from the guest.

## Path and naming contract

Defined once in `modules/lib/phone-pipeline.nix`; the host and guest modules import it.

| Name | Value |
|---|---|
| Syncthing folder id | `phone` |
| Host ciphertext tree | `/var/lib/data/phone-untrusted` (0700 `vault`, no versioning) |
| Virtiofs tag / mount | `phone-untrusted` → `/mnt/kanbei/phone-untrusted` (read-only) |
| Host password contract | `/run/secrets/phone-folder-password` (sops, 0400) |
| Guest contract | `/run/kanbei-secrets/phone-folder-password` (read-only share) |
| Staged password | `/var/lib/kanbei/secrets/phone-folder-password` (0400 root, LUKS) |
| Decrypted tree | `/var/lib/kanbei/phone` (`manifest.json`, `sms/`, `contacts/`, `health/`) |
| Service state | `/var/lib/kanbei/phone-state/{index.json,heartbeat.json,batches/}` |
| Per-file cap | 16 MiB |

Canonical decrypted layout:

| Kind | Accepted name | Lands at |
|---|---|---|
| SMS + MMS | `messages-YYYY-MM-DD.zip` | `sms/` |
| Call log | `calls-YYYY-MM-DD.json` | `sms/` |
| Contacts | `contacts-YYYY-MM-DD.json` | `contacts/` |
| Health | `health_YYYY-MM-DD.json` | `health/` |

SMS Import/Export has one scheduled-export directory, so it writes contacts into `sms/`
on the phone; the decrypt service classifies by filename and routes contacts to
`contacts/`. Unknown names are reported in the manifest's `rejected` list and not
installed; they do not fail the run.

## Host: the receive-encrypted folder

`modules/nixos/vault-sync.nix` adds a second folder to the existing `vault` Syncthing
instance:

- `type = "receiveencrypted"`; this host is the *untrusted* peer.
- shared only with the `phone` device in `modules/syncthing-devices.nix`.
- path `/var/lib/data/phone-untrusted`, created `0700 vault:vault` by tmpfiles.
- no versioning: encrypted blocks cannot be reused between files, so a versioner would
  duplicate the whole ciphertext per change.
- no `encryptionPassword` in the host config: the password lives on the phone and in the
  guest. Adding it here would defeat the point.

The folder id must match on both sides. When the phone shares the folder, use the
advanced folder setting to set the id to `phone` (Syncthing-Fork: Folder → Advanced →
Folder ID), or delete and re-add the folder on the host after accepting the phone's id.
Renaming the id later means re-sharing.

### Backup semantics

- The host tree is ciphertext under `/var/lib/data`, which both host restic jobs already
  walk: the ciphertext is backed up, as intended.
- The plaintext tree exists only inside `/var/lib/microvms/kanbei/data.img`; the
  `kanbei-{r2,local}` jobs snapshot that image (LUKS ciphertext) with the guest stopped.
- No restic job may name `/var/lib/kanbei/phone`; `modules/nixos/kanbei-vm.nix` asserts
  it and asserts that a job covers `/var/lib/data`.

## Password custody

1. Generate once: `openssl rand -base64 32`. Store it in the password manager.
2. `sops secrets/smortress.yaml` → add `phone-folder-password: <value>`.
3. `modules/hosts/smortress/secrets.nix` declares it (already committed); sops-nix
   installs it 0400 root at `/run/secrets/phone-folder-password`.
4. `kanbei-phone-password.service` copies it to the read-only `kanbei-secrets` share
   (`/run/kanbei-secrets/phone-folder-password`, 0400). `sops.secrets.phone-folder-password`
   restarts that unit on rotation.
5. The guest's `syncthing-decrypt.service` stages it into the LUKS volume at 0400 and
   refuses to run when neither the contract nor a staged copy exists. The staged copy
   survives a boot without the sops file; the contract always wins when present.

The host never passes the password on a command line: the wrapper reads the staged file
and sets `FOLDER_PASSWORD` in the `syncthing decrypt` child's environment. Rotation means
changing the phone side and the sops value in the same window; Syncthing re-encrypts the
folder, so the first sync after a change is a full transfer.

## Phone setup

### Common (Syncthing-Fork)

- Install Syncthing-Fork (`com.github.catfriend1.syncthingfork`), pair the host using the
  `smortress` device id from `modules/syncthing-devices.nix` (the phone's id is already in
  that table).
- Create the folder `/storage/emulated/0/Sync/phone`, folder id `phone`, share it to
  `smortress` with the folder password from above.
- Grant the battery-optimisation exemption (Settings → Apps → Syncthing-Fork → Battery →
  Unrestricted) and disable any OEM "battery saver" for it. Without it the folder can stop
  syncing for hours under Doze.

### SMS Import / Export

Install `com.github.tmo1.sms_ie` (v2.12.0 audited) and apply
[`mobile/sms-ie/SETTINGS.md`](../mobile/sms-ie/SETTINGS.md): scheduled export on, 02:30
daily, interval 1, directory `/Sync/phone/sms`, messages/calls/contacts on, old-export
deletion off, binary MMS data off, battery exemption on. Output is the v2 NDJSON ZIP plus
the two JSON files.

Blocked numbers are **not** in the pipeline: the `BlockedNumberContract` needs the app to
be the default SMS/phone app, which is a manual switch. A one-off manual export is the
only way to include them; the daily heartbeat does not cover them.

### healthconnect-export fork

The upstream app uploads to Drive/webhook and therefore holds the `INTERNET` permission.
The fork at [`mobile/healthconnect-export/`](../mobile/healthconnect-export/FORK.md) is
pinned to upstream `e33563e29b387c32d331215725dae46d1bebd6a2`, removes those features and
the network permission/dependencies, and writes through a Storage Access Framework
directory instead of the app-private path. Build and sideload:

```sh
git clone https://github.com/nachojrs/healthconnect-export && cd healthconnect-export
git checkout e33563e29b387c32d331215725dae46d1bebd6a2
git apply /path/to/nix-config/mobile/healthconnect-export/fork.patch
bash /path/to/nix-config/mobile/healthconnect-export/verify-manifest.sh .
./gradlew :app:assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk
```

Open once: grant Health Connect read access, choose `/Sync/phone` as the export tree (the
app writes `health/health_<date>.json`), and allow background execution. The manifest
checker must pass before the APK is installed; a rebase that reintroduces `INTERNET` or a
Drive/webhook dependency fails it.

### Schedules

- `02:30` daily: SMS Import/Export (messages, calls, contacts).
- Daily (WorkManager, default hour 02:00): health export; the fork schedules on launch
  and re-enqueues after reboot.
- Syncthing runs continuously; the guest decrypt timer runs hourly at `:00` plus up to
  2 minutes of jitter and once 5 minutes after guest boot.

## Guest: `syncthing-decrypt`

`modules/nixos/kanbei-phone.nix` (guest module, imported by `kanbei-vm.nix`):

1. Refuse to run without a usable password (exit 10) or when the staged file is not 0400
   (exit 13).
2. Prove the source is receive-encrypted: `.stfolder/syncthing-encryption_password_token`
   must parse with a non-empty folder id, and every top-level entry must be
   `.stfolder`/`.stignore`/`.stversions` or a `*.syncthing-enc` directory. A plaintext
   folder is exit 11; the existing tree is untouched.
3. `syncthing decrypt --to <temp>` with `FOLDER_PASSWORD` in the environment.
4. Merge into a staging tree: existing decrypted files are hardlinked (the LUKS volume is
   the archive; a phone-side retention run never deletes history), new or changed files are
   copied, content hashes dedupe across names, and files over 16 MiB are rejected.
5. Write `manifest.json`, then atomically exchange the staging tree with
   `/var/lib/kanbei/phone` (`renameat2(RENAME_EXCHANGE)`; two renames only if the kernel
   or filesystem refuses, leaving a sub-millisecond window).
6. Newly consumed files produce one or more batch envelopes in
   `phone-state/batches/phone-<utc>-<seq>.json` in the inbox contract
   (`v`,`source=phone`,`kind=batch`,`seq`,`sent_at`,`items`), chunked at 500 items.
   `phone-state/heartbeat.json` is rewritten on every run (status, file count, bytes,
   sequence, consumed count); failures write an `alert` batch and an error heartbeat.

Exit codes: `10` no password, `11` not a receive-encrypted folder, `12` `syncthing decrypt`
failed, `13` password contract (empty, wrong mode, unreadable). The timer retries hourly;
the journal carries the message.

## Verification

Host:

```sh
sudo -u vault syncthing cli config folders list        # phone-untrusted, type receiveencrypted
sudo ls -ld /var/lib/data/phone-untrusted              # 0700 vault vault
sudo -u smores test -r /var/lib/data/phone-untrusted   # must fail
sudo systemctl status kanbei-phone-password.service
sudo ls -l /var/lib/kanbei-vm/secrets/phone-folder-password   # 0400 root
```

Guest (console):

```sh
systemctl list-timers 'syncthing-decrypt*'
systemctl start syncthing-decrypt.service
journalctl -u syncthing-decrypt -n 40 --no-pager
ls -l /var/lib/kanbei/phone /var/lib/kanbei/phone-state/batches
cat /var/lib/kanbei/phone/manifest.json
```

A day's pipeline is complete when the manifest lists the new `sms/`, `contacts/` and
`health/` files and a batch with the same items exists. Export validation before trusting
a new app version:

```sh
python3 mobile/sms-ie/validate-export.py <sample-export-directory>
```

The wrapper and validator unit tests are `tests/test_phone_pipeline.py`
(`unit-tests` check): password missing/wrong mode, plaintext folder refusal, atomic swap,
dedupe, size cap, heartbeat/alert batches, SMS schema fixtures, and the fork's
positive/negative manifest fixtures.

## Residuals

- Syncthing's untrusted-device encryption is still labelled beta upstream. The folder id
  and password are both required to decrypt; both are in the guest/password manager.
- Host root (and therefore a touch-authorized maki) can read the ciphertext but not the
  plaintext; physical access to the guest's LUKS image plus the swtpm state is the host
  boundary already accepted for Kanbei.
- MMS binary payloads and BLOBs are excluded by the documented SMS settings; the size cap
  rejects them if the toggles are turned back on.
- Blocked numbers are not exported daily (default-app requirement).
- The phone's exports are only as fresh as the phone's battery/network; the guest
  heartbeat makes a stale source visible once Kanbei's inbox reader surfaces it (#600).
