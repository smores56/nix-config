# Synthetic Bitwarden export

`synthetic-export.json` is a synthetic password-protected Bitwarden export for
tests and for trying the dashboard. Every credential in it is fake.

- Export password: `synthetic-export-fixture-4f9c1a`
- Folder: `Family Access`
- Items (custom field `fa_id` in parentheses):
  - `START HERE` (`start`) - secure note
  - `Email - Tuta` (`email`) - `family-test@tuta.com` / `okMfeBD8ush7HHMLbszsV5Bw`
  - `Immich` (`immich`) - `family` / `dsD9q4dWwH4KJ6NvMV4iLra9`
  - `Data Recovery` (`data-recovery`) - secure note with placeholder keys

The names match `public/manifest.json`, so loading the file in the PWA matches
every manifest item.

Regenerate with `deno run --allow-read --allow-write make-fixture.ts <password>`
(new random credentials each run).
