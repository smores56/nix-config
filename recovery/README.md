# Recovery kit

Treat this as future-inheritance, not an everyday password manager.

- The page is a **static, public** site at `recovery.sammohr.dev`. It contains no secrets.
- The family enters a separate **recovery password** from the sealed letter or drive.
- The password decrypts a small `data-keys.enc` blob in the browser.
- The blob contains only the R2 read-only token, restic password and data paths.
  It does not contain the Bitwarden root.
- Data restore runs client-side with the TypeScript restic reader. No server sees
  the password, keys, or files.

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

### Fixtures

- `test-fixtures/restic/` is a restic repository (password `family-access-fixture`)
  holding a small tree that exercises the reader: nested documents, an empty
  file, a name longer than 200 bytes and binary content. The page browses real
  snapshots; the fixture only pins the reader, so it does not need the production
  layout and needs neither JDK nor a mount namespace.

### Sentinel

`deno task blob` and `deno task blob --check-only` walk R2 -> restic and read
`var/lib/data/vault/Documents/sentinel.txt` (`src/sentinel.ts`). Create it once
with `sudo vault` open, in a normal shell (not the root shell):

```sh
mkdir -p ~/.local/share/vault/Documents
echo "sentinel: 6f1c2a7e" > ~/.local/share/vault/Documents/sentinel.txt
```

then let a restic run pick it up.

- The blob is public but encrypted; the recovery password is the data gate.
- The recovery password is separate from the Bitwarden master password.
- The page must not persist the password or data keys. They live in memory
  for the tab's lifetime and disappear when it is closed or refreshed; there is
  no lock button or idle timeout.

## Data-keys blob

`deno task blob` prompts for the recovery password (twice), reads `r2-access-key-id-readonly`, `r2-secret-access-key-readonly`
and `restic-password` from `../secrets/smortress.yaml`, encrypts
the payload with Argon2id (3 passes, 64 MiB, 4 lanes) plus AES-256-GCM, writes
`public/data-keys.enc`, then decrypts it again and walks R2 -> restic -> the vault sentinel. There is no password-file option and no legacy scrypt
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
blob. It needs the recovery password only: the blob already carries the restic credentials, so the check also proves they
are the right ones. It
reads the newest R2 snapshot, so a sentinel added after the last backup fails
until a backup runs.

## Restore in the page

`Restore all files` walks the selected snapshot and writes every
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
```

`deno task smoke` serves `dist/` on a loopback port and asserts the built page
renders its shell, unlocks from a link fragment and reaches the account and
file UI, which is the only check that
notices a broken bundle, a CSP that blocks the module, or a blob the browser
cannot open. Both run in `.github/workflows/recovery.yml` on every
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

The page shows only the password field until the blob decrypts; everything else
lives behind `#unlocked` so a relative opening it does not read account
instructions before they have proven they hold the letter. After unlock the
account list is a short sidebar on wide screens, and the file browser takes the
rest of the width and height; on narrow screens the account list stacks above
the browser.

Browsing starts at `dataRoot` (`src/restore.ts`): the directory every configured
data path shares, which is `var/lib/data`, so the top level is `photos/`,
`vault/` and `db/` rather than the snapshot root's single `var/`. The browser
renders that level as a tree of native `<details>` disclosures; each folder
loads its children from restic only when it is opened.
