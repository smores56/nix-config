# Family Access PWA

Treat this as future-inheritance, not an everyday password manager.

- The PWA is a **static, public** site. It contains no secrets.
- The family enters a separate **PWA password** from the sealed letter or drive.
- The password decrypts a small `data-keys.enc` blob in the browser.
- The blob contains only the R2 read-only token, restic password, vault password,
  and data paths. It does not contain the Bitwarden root.
- Data restore is planned to run client-side with the TypeScript restic reader
  and Cryptomator TS. No server sees the password, keys, or files.

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

## T1 scope

This task scaffolds the PWA, the blob envelope, the manifest validator/renderer,
and the unlock flow. The real data-keys blob is produced in T5; until then the
page says no blob is deployed. The restic reader, Cryptomator provider,
Bitwarden export reader, and Cloudflare Pages deployment are later tasks.

## Security notes

- Never commit a plaintext data-keys payload or the PWA password.
- The blob is public but encrypted; the PWA password is the data gate.
- The PWA password is separate from the Bitwarden master password.
- The PWA must not persist the password or data keys; lock clears them.
