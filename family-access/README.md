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
bun install
bun test
bun run build
```

The build writes `dist/`. Serve it over HTTPS or on `localhost`; `crypto.subtle` requires a secure context.
Opening `index.html` with `file://` is not supported by the fetch-based blob/manifest
loader, and plain HTTP from a LAN address will disable unlock.

## Scope so far

The PWA scaffolds the blob envelope, the manifest validator/renderer, the unlock
flow, and the restic snapshot browser. The real data-keys blob is produced in
T5; until then the page says no blob is deployed. The Bitwarden export reader
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
  `test-fixtures/CreateVault.java` for how it was produced.
- `test-fixtures/restic-cryptomator/` stores the same vault at
  `var/lib/data/vault` in a restic repository (password `family-access-fixture`).

### Real-vault sentinel

Run the same reader against the production vault; it prints the sentinel file
and fails loudly if anything does not decrypt. Prefer password files: exported
environment variables are readable by any same-UID process.

```sh
# local ciphertext directory
bun run sentinel --local /var/lib/data/vault \
  --vault-password-file ~/.config/family-access/vault-password

# local restic repository
bun run sentinel --repo /var/backup/restic --prefix var/lib/data/vault \
  --restic-password-file ~/.config/family-access/restic-password \
  --vault-password-file ~/.config/family-access/vault-password

# Cloudflare R2 (read-only token)
R2_REPOSITORY=... R2_ENDPOINT=... R2_BUCKET=... \
R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
  bun run sentinel --r2 --prefix var/lib/data/vault \
  --restic-password-file ~/.config/family-access/restic-password \
  --vault-password-file ~/.config/family-access/vault-password
```

`VAULT_PASSWORD` and `RESTIC_PASSWORD` still work as a fallback.

## Security notes

- Never commit a plaintext data-keys payload or the PWA password.
- The blob is public but encrypted; the PWA password is the data gate.
- The PWA password is separate from the Bitwarden master password.
- The PWA must not persist the password or data keys; lock clears them.
