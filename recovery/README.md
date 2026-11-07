# Recovery kit

Treat this as future-inheritance, not an everyday password manager.

- The page is a **static, public** site at `recovery.sammohr.dev`. It contains no secrets.
- The family enters a separate **recovery password** from the sealed letter or drive.
- The password decrypts a small `data-keys.enc` blob in the browser.
- The blob contains only the R2 read-only token, restic password, vault password,
  and data paths. It does not contain the Bitwarden root.
- Data restore runs client-side with the TypeScript restic reader and a
  Cryptomator vault reader. No server sees the password, keys, or files.

## Build and test

```sh
cd recovery
deno install
deno task test
deno task build
```

The build writes `dist/`. Serve it over HTTPS or on `localhost`; `crypto.subtle` requires a secure context.

Tooling is Deno (`deno.json`): `deno task typecheck`, `deno task build`, `deno task test`. The tasks declare only the permissions they need (read for the app and fixtures, env for the AWS SDK probe, read/write/run for the esbuild bundle). The browser artifact is plain ESM built with esbuild.
Opening `index.html` with `file://` is not supported by the fetch-based blob/manifest
loader, and plain HTTP from a LAN address will disable unlock.

## Cryptomator vault reader

`src/cryptomator/vault.ts` reads vault format 8 with `cipherCombo: SIV_GCM`:
AES-SIV names and directory IDs, the scrypt/AES-KW masterkey file, the signed
`vault.cryptomator`, and AES-GCM file contents. It is read-only and refuses
symlinks, other cipher combos, and files above 256 MiB.

`ResticVaultProvider` maps the vault's ciphertext paths onto a restic snapshot,
so the page can list and decrypt selected documents without restoring the whole
vault. `LocalVaultProvider` does the same on a local directory.

The reader is derived from `cryptomator-ts` (MIT, `src/cryptomator/MIT-LICENSE.txt`),
with the content crypto and name handling corrected against the published vault
format and verified against vaults created by cryptofs 2.8.0 / cryptolib 2.2.0.

### Fixtures

- `test-fixtures/cryptomator-vault/` is a reference vault created by the Java
  implementation (password `family-access-vault-fixture`). It covers root and
  nested names, 0/1/32 KiB/32 KiB+1/100 KB files, a shortened file name, a
  shortened directory, an NFC name, a symlink, `dirid.c9r` backups, and the
  production layout of the sentinel at `Documents/sentinel.txt`. `CreateVault.java`
  reproduces it: compile with a JDK 25 and the cryptomator-cli `mods/` and
  `libs/` jars (the jars use class files a JDK 21 cannot load), then run it with
  the vault password and `"vault-sentinel: 6f1c2a7e"`.
- `test-fixtures/restic-cryptomator/` stores the same vault at
  `/var/lib/data/vault` in a restic repository (password `family-access-fixture`).
  The path matters: the tree must read `var/lib/data/vault`, so build it inside a
  mount namespace where the vault really sits there (`unshare -rm`,
  `mount --bind <tmp>/var /var`, `restic backup /var/lib/data/vault`).
  `src/cryptomator/vault.test.ts` pins the fixture root's ciphertext path, so
  regenerating means updating that one assertion with the value the reader prints.

### Real-vault sentinel

Run the same reader against the production vault; it prints the sentinel file
and fails loudly if anything does not decrypt. The sentinel is
`Documents/sentinel.txt` inside the vault (`src/sentinel.ts`); the vault root
stays the Cryptomator layout. Prefer password files: exported environment
variables are readable by any same-UID process.

```sh
# local ciphertext directory
deno task sentinel --local /var/lib/data/vault \
  --vault-password-file ~/.config/recovery/vault-password

# local restic repository
deno task sentinel --repo /var/backup/restic --prefix var/lib/data/vault \
  --restic-password-file ~/.config/recovery/restic-password \
  --vault-password-file ~/.config/recovery/vault-password

# Cloudflare R2 (read-only token)
R2_REPOSITORY=... R2_ENDPOINT=... R2_BUCKET=... \
R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
  deno task sentinel --r2 --prefix var/lib/data/vault \
  --restic-password-file ~/.config/recovery/restic-password \
  --vault-password-file ~/.config/recovery/vault-password
```

`VAULT_PASSWORD` and `RESTIC_PASSWORD` still work as a fallback.

## Security notes

- Never commit a plaintext data-keys payload or the recovery password.
- The blob is public but encrypted; the recovery password is the data gate.
- The recovery password is separate from the Bitwarden master password.
- The page must not persist the password or data keys; lock clears them.

## Data-keys blob

`deno task blob` prompts for the recovery password (twice) and the Cryptomator
password, reads `r2-access-key-id-readonly`, `r2-secret-access-key-readonly`
and `restic-password` from `../secrets/smortress.yaml`, encrypts
the payload with Argon2id (3 passes, 64 MiB, 4 lanes) plus AES-256-GCM, writes
`public/data-keys.enc`, then decrypts it again and walks R2 -> restic -> the
Cryptomator sentinel. There is no password-file option and no legacy scrypt
envelope. The blob is public ciphertext and is committed; the build copies it
when present.

Before the blob is renamed into place it asks for the recovery password a third
time, from scratch, and opens the file that was just written with that entry.
The first two prompts only prove the two entries agree with each other; they
cannot prove the letter will print a password the browser also derives, because
they reuse the string captured in memory. Retype the password at every prompt:
a newline or an escape sequence pasted in is rejected, and an accented
character is normalized to NFC on both the build and browser side, but nothing
can rescue a password that was transcribed differently than it will be printed.

`deno task blob --check-only` repeats just the last step against the committed
blob. It needs the recovery password only: the blob already carries the restic and
Cryptomator credentials, so the check also proves they are the right ones. It
reads the newest R2 snapshot, so a sentinel added after the last backup fails
until a backup runs.

## Restore in the page

`Restore everything to a folder` walks the selected snapshot and writes every
file into a folder the operator picks (`src/restore.ts` strips the snapshot's
shared root, so the folder starts at `photos/`). Each file streams through
restic blob by blob, so memory stays at one blob whatever the total size, and
a file already present with the same size is skipped, which makes a stopped run
resumable.

The directory handle comes from the File System Access API. WebKit implements
neither `showDirectoryPicker` nor a usable Service-Worker streaming download on
macOS, iPadOS or iOS, so Safari downloads single files only (buffered, capped at
256 MiB). The letter tells the family to use Chrome on the Mac for the full
library and keeps Safari for reading and single files.

## Deployment

`nix run .#cloudflare-apply` owns the Cloudflare side (`tofu/pages.tf`): the
`recovery` Pages project, the `recovery.sammohr.dev` custom domain, and the DNS
record that keeps that name off the `*.sammohr.dev` tunnel wildcard.
`.github/workflows/recovery.yml` typechecks, tests and builds on every change
under `recovery/`, then uploads `dist/` to the project on push to `main` using a
Pages-only API token (procedure in `docs/key-rotation.md`). The workflow never
creates the project: if it reports the project missing, run
`sudo nix run .#cloudflare-apply` first.

## Checks

```sh
deno task typecheck
deno task test
deno task build
deno task smoke    # headless Chrome: CHROME=<path> or --chrome <path>
deno task sentinel --repo test-fixtures/restic-cryptomator --prefix var/lib/data/vault
```

`deno task smoke` serves `dist/` on a loopback port and asserts the built page
renders its shell and reaches the unlock prompt, which is the only check that
notices a broken bundle or a CSP that blocks the module. The sentinel command
needs `VAULT_PASSWORD` and `RESTIC_PASSWORD` (the fixture values are in the
fixture list above). Both run in `.github/workflows/recovery.yml` on every
change under `recovery/`, before the deploy job.

## Recovery links

The letter and the drive can carry a link of the form
`https://recovery.sammohr.dev/#<password>` (percent-encoded). The password sits in
the URL *fragment*, which no browser sends to a server, so it cannot reach
Cloudflare's access logs, a proxy, or a `Referer` header. `src/main.ts` reads the whole fragment,
strips it with `history.replaceState` before the Argon2 derivation starts, and
unlocks; a link that fails falls back to the typed password with an error message.

A link is the password in another form: it is printed on the same paper and must
not be sent by message. Any fragment is treated as a password, so a stray
`#anchor` fails and the page asks for the typed password instead.
