# Family Access PWA

Treat this as future-inheritance, not an everyday password manager.

- The PWA is a **static, public** site. It contains no secrets.
- The family enters a separate **PWA password** from the sealed letter or drive.
- The password decrypts a small `data-keys.enc` blob in the browser.
- The blob contains only the R2 read-only token, restic password, vault password,
  and data paths. It does not contain the Bitwarden root.
- Data restore runs client-side with the TypeScript restic reader and a
  Cryptomator vault reader. No server sees the password, keys, or files.

## Build and test

```sh
cd family-access
deno install
deno task test
deno task build
```

The build writes `dist/`. Serve it over HTTPS or on `localhost`; `crypto.subtle` requires a secure context.

Tooling is Deno (`deno.json`): `deno task typecheck`, `deno task build`, `deno task test`. The tasks declare only the permissions they need (read for the app and fixtures, env for the AWS SDK probe, read/write/run for the esbuild bundle). The browser artifact is plain ESM built with esbuild; the future Mac CLI will be a `deno compile` binary.
Opening `index.html` with `file://` is not supported by the fetch-based blob/manifest
loader, and plain HTTP from a LAN address will disable unlock.

## Scope so far

The PWA scaffolds the blob envelope, the manifest validator/renderer, the unlock
flow, and the restic snapshot browser. The data-keys blob is produced by
`deno task blob`; until it is committed the page says no blob is deployed. The Bitwarden export reader
and the Cloudflare Pages deployment are later tasks.

## Cryptomator vault reader

`src/cryptomator/vault.ts` reads vault format 8 with `cipherCombo: SIV_GCM`:
AES-SIV names and directory IDs, the scrypt/AES-KW masterkey file, the signed
`vault.cryptomator`, and AES-GCM file contents. It is read-only and refuses
symlinks, other cipher combos, and files above 256 MiB.

`ResticVaultProvider` maps the vault's ciphertext paths onto a restic snapshot,
so the PWA can list and decrypt selected documents without restoring the whole
vault. `LocalVaultProvider` does the same on a local directory.

The reader is derived from `cryptomator-ts` (MIT, `src/cryptomator/MIT-LICENSE.txt`),
with the content crypto and name handling corrected against the published vault
format and verified against vaults created by cryptofs 2.8.0 / cryptolib 2.2.0.

### Fixtures

- `test-fixtures/cryptomator-vault/` is a reference vault created by the Java
  implementation (password `family-access-vault-fixture`). It covers root and
  nested names, 0/1/32 KiB/32 KiB+1/100 KB files, a shortened file name, a
  shortened directory, an NFC name, a symlink, and `dirid.c9r` backups. See
  `test-fixtures/CreateVault.java` for how it was produced. Its sentinel sits
  at the vault root, not in `Documents/`: `src/cryptomator/vault.test.ts` pins
  the fixture's root listing and the ciphertext path derived from its
  masterkey, so moving it means regenerating both together.
- `test-fixtures/restic-cryptomator/` stores the same vault at
  `var/lib/data/vault` in a restic repository (password `family-access-fixture`).

### Real-vault sentinel

Run the same reader against the production vault; it prints the sentinel file
and fails loudly if anything does not decrypt. The sentinel is
`Documents/sentinel.txt` inside the vault (`src/sentinel.ts`); the vault root
stays the Cryptomator layout. Prefer password files: exported environment
variables are readable by any same-UID process.

```sh
# local ciphertext directory
deno task sentinel --local /var/lib/data/vault \
  --vault-password-file ~/.config/family-access/vault-password

# local restic repository
deno task sentinel --repo /var/backup/restic --prefix var/lib/data/vault \
  --restic-password-file ~/.config/family-access/restic-password \
  --vault-password-file ~/.config/family-access/vault-password

# Cloudflare R2 (read-only token)
R2_REPOSITORY=... R2_ENDPOINT=... R2_BUCKET=... \
R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
  deno task sentinel --r2 --prefix var/lib/data/vault \
  --restic-password-file ~/.config/family-access/restic-password \
  --vault-password-file ~/.config/family-access/vault-password
```

`VAULT_PASSWORD` and `RESTIC_PASSWORD` still work as a fallback.

## Security notes

- Never commit a plaintext data-keys payload or the PWA password.
- The blob is public but encrypted; the PWA password is the data gate.
- The PWA password is separate from the Bitwarden master password.
- The PWA must not persist the password or data keys; lock clears them.

## Data-keys blob

`deno task blob` prompts for the PWA password (twice) and the Cryptomator
password, reads `r2-access-key-id-readonly`, `r2-secret-access-key-readonly`
and `restic-password` from `../secrets/smortress.yaml`, encrypts
the payload with Argon2id (3 passes, 64 MiB, 4 lanes) plus AES-256-GCM, writes
`public/data-keys.enc`, then decrypts it again and walks R2 -> restic -> the
Cryptomator sentinel. There is no password-file option and no legacy scrypt
envelope. The blob is public ciphertext and is committed; the build copies it
when present.

`deno task blob --check-only` repeats just the last step against the committed
blob. It needs the PWA password only: the blob already carries the restic and
Cryptomator credentials, so the check also proves they are the right ones. It
reads the newest R2 snapshot, so a sentinel added after the last backup fails
until a backup runs.

## Bitwarden export dashboard

The manifest tells the family which Bitwarden items to open. If they also have a
password-protected Bitwarden JSON export, the page can decrypt it in memory and
show each item's username, password, TOTP, notes, and custom fields next to the
instructions.

`src/bitwarden/export.ts` implements Bitwarden's export format: PBKDF2-SHA256 or
Argon2id over the export salt, HKDF-Expand of the result into separate `enc` and
`mac` keys, then AES-256-CBC + HMAC-SHA256 cipher strings (`2.iv|ct|mac`).
Limits: 2,000,000 PBKDF2 iterations, 64 Argon2 iterations, 128 MiB Argon2 memory, 32 MiB export file.
Nothing is stored: the plaintext export lives only in the tab and is dropped by
"Lock and clear".

Vault items are matched to the manifest by the `fa_id` custom field, with the
vault UUID as a cross-check: a UUID that no longer matches the item means the
Bitwarden item was deleted and recreated. `validate` also checks the folder and
item type when the manifest sets `folder`/`type`.

```sh
deno task validate --export ~/bitwarden_export.json \
  --export-password-file ~/.config/family-access/export-password \
  --restic-dir /var/backup/restic \
  --restic-password-file ~/.config/family-access/restic-password
```

To try the dashboard without a real vault, load
`test-fixtures/bitwarden/synthetic-export.json` with the password in that
directory's README; its four synthetic items match the shipped manifest.

Exit status is non-zero when any required item is missing, a UUID/fa_id/folder/
type does not match, or the restic repository cannot be opened. A plaintext
export is accepted with a warning; the password-protected form is preferred.
