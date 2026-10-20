# Manual steps

Everything here is an operator action: work the repo cannot do from Nix.
`checks.manual-steps-sync` derives the inventory from the configuration, so
`nix flake check` fails when an item below is missing an anchor, when an anchor
no longer exists in the config, or when this file still contains an unresolved
placeholder marker.

An anchor is an HTML comment on its own line:

```html
<!-- manual-step: <kind>/<id> -->
```

Kinds: `host`, `secret`, `provider`, `dataset`, `service`, `app`, `alert`.
Adding a host directory, sops key, Tofu provider or notification, backup
dataset, public service, flake app, or alert path means adding its anchor with
real instructions.

## Hosts

The host list comes from `modules/hosts/*/`.

### smortress

<!-- manual-step: host/smortress -->

The always-on server (NixOS, x86_64), and the only host that decrypts
`secrets/smortress.yaml`. Reinstall from a blank disk with:

```sh
nix run .#host-key -- smortress
nix run .#install -- smortress root@<target-ip>
```

`install` wipes the target's disks, applies `modules/hosts/smortress/disko.nix`,
generates `hardware.nix`, and delivers the pre-generated host key. Commit the
generated hardware config, then run `nix run .#bootstrap`.

- **Backup disk**: `/dev/disk/by-label/backup` (`backup.device`). Format and
  label a second disk once (`mkfs.ext4 -L backup /dev/sdX`). The module only
  mounts it, with `nofail`; the backup units declare `RequiresMountsFor` and
  fail loudly when it is absent.
- **Host key**: `/etc/ssh/ssh_host_ed25519_key` is the age recipient that
  decrypts the host's sops file. Losing it means restoring the key or re-keying
  (see Recovery in `README.md`).
- **Out-of-band access**: the physical console. There is no inbound SSH port;
  SSH is tunnel-only.

### smorespro

<!-- manual-step: host/smorespro -->

Intel laptop (NixOS). Install with the same `host-key`/`install` flow as
smortress, then enroll the fingerprint reader once after activation:

```sh
fprintd-enroll
fprintd-verify
fprintd-list "$USER"
```

Fingerprint auth is for the lock screen only; it is deliberately not enabled
for `sudo`/`su`.

Maki's personal profile on this host has no `NEURALWATT_API_KEY` or
`BRAVE_API_KEY`: those secrets live only in `secrets/smortress.yaml`. Use the
`work` AI profile or provision keys out of band.

### smoreswork

<!-- manual-step: host/smoreswork -->

The employer's macOS laptop (home-manager only; no NixOS configuration). Install
Nix, then:

```sh
nix run github:smores56/nix-config#bootstrap
```

`bootstrap` derives the configuration name from the machine's hostname and
user; on a laptop whose OS hostname is not `smoreswork`, override both:
`BOOTSTRAP_USER=sam BOOTSTRAP_HOST=smoreswork ...`.

MDM enrollment, FileVault, and OS updates stay with the employer; this repo only
manages the user environment.

## Secrets

All secrets live in `secrets/smortress.yaml`, which only smortress can decrypt.
Edit them with:

```sh
nix shell nixpkgs#sops -c sops secrets/smortress.yaml
```

After editing, commit and run `sudo nixos-rebuild switch` on smortress so
sops-nix redeploys `/run/secrets`. Never place a secret in the Nix store.

### cloudflare-api-token

<!-- manual-step: secret/cloudflare-api-token -->

One root-only token shared by OpenTofu and the email alert sender. Mint it at
<https://dash.cloudflare.com> → My Profile → API Tokens with:

- Zone:DNS:Edit for `sammohr.dev`;
- Access: Apps and Policies:Edit;
- Notifications:Edit;
- Email Sending:Edit.

Readers: `nix run .#cloudflare-*` and the `cloudflare-email` /
`backup-freshness` units. Rotate in the dashboard, update this key, rebuild, and
prove it with `sudo nix run .#cloudflare-plan`.

### cloudflared-credentials

<!-- manual-step: secret/cloudflared-credentials -->

The tunnel credentials JSON (`TunnelID`, `TunnelSecret`, `AccountTag`). The
`TunnelID` field is the authoritative tunnel UUID used by OpenTofu; no UUID is
authored in the repo and `webProxy.tunnelName` is only a label.

Create or reissue the tunnel under Zero Trust → Networks → Tunnels and paste the
JSON here. Changing the tunnel means rebuilding the host and re-running
`cloudflare-apply`.

### github-key-pat

<!-- manual-step: secret/github-key-pat -->

User-readable token used by `bootstrap` for `gh auth login --with-token`.
Classic token with `write:public_key` and `write:ssh_signing_key`, or a
fine-grained token with the account permissions "Git SSH keys: write" and "SSH
signing keys: write". Mint at GitHub → Settings → Developer settings → Personal
access tokens.

A lapsed token fails `bootstrap` hard; blank the secret and rebuild to fall back
to the device-code flow.

### github-repo-pat

<!-- manual-step: secret/github-repo-pat -->

Classic `repo`-scoped token, root-only, read by the GitHub mirror and metadata
units (`githubBackup.tokenFile`): ghorg, `python-github-backup`, and the
verifier (`gh`, via `GH_TOKEN` in its environment). ghorg embeds it in git's
argv, so it is visible in `/proc/<pid>/cmdline` during a run; the backup guide
records that accepted window. pgb receives it as a `file://` path, so it stays
out of argv. Fine-grained tokens cannot read wikis, so `--clone-wiki` would
silently omit them. Mint at GitHub → Settings → Developer settings → Personal
access tokens.

The mirror's probe repo (`sdlc`) must be refreshed on every run; a token
that is valid but has lost `repo` scope fails the run. The verifier also fails
when the token's repo listing no longer matches the mirror, so a scope loss is
caught the same night.

### proton-pass-pat

<!-- manual-step: secret/proton-pass-pat -->

`pass-cli` personal access token, user-readable, scoped read-only to the
Hosting and Identity vaults. Proton caps these at one year. Used by `bootstrap`,
`ssh-pub-keys`, and the `cloudflared-access` wrapper. Mint under Proton Pass →
Settings → Access tokens.

### calibre-password

<!-- manual-step: secret/calibre-password -->

OPDS password for the single `smores56` user, user-readable. The service
re-applies it on every start, so rotating is: edit this key, rebuild, restart
`calibre-server` (the rebuild restarts it) and refresh OPDS clients.

### neuralwatt-api-key

<!-- manual-step: secret/neuralwatt-api-key -->

Hosted-inference key, user-readable, exported by the fish init as
`NEURALWATT_API_KEY` for maki's provider config. Rotate in the Neuralwatt
console, update this key, rebuild, and open a new shell.

### brave-api-key

<!-- manual-step: secret/brave-api-key -->

Brave Search API key, user-readable, exported by the fish init for maki's
websearch plugin. Page Assist keeps its own copy in the browser. Rotate in the
Brave dashboard, update this key, rebuild, and open a new shell.

## Providers

Tofu providers come from `tofu/versions.tf`; notification policies come from
`tofu/main.tf`.

### cloudflare

<!-- manual-step: provider/cloudflare -->

The only OpenTofu provider. The zone `sammohr.dev` already lives in the account;
OpenTofu manages a wildcard proxied CNAME, the `ssh`/`llm` Access applications,
the email allow-list and service-auth policies, and the tunnel-health and
service-token-expiry notifications.

Manual, one-time (dashboard):

- Create the tunnel and store its credentials (see
  `cloudflared-credentials`).
- Mint the Access service token(s) used by unattended clients; the service-auth
  policy references them. OpenTofu does not create tokens. One
  `any_valid_service_token` policy covers both `ssh` and `llm`, so any service
  token in the account reaches both endpoints.
- Onboard the Email Service sending subdomain (`send.sammohr.dev`) and add its
  SPF/DKIM/DMARC records. Verify the destination (`sam@sammohr.dev`). Leave the
  apex DMARC record alone (`p=reject`).
- Delete stale DNS records, Access applications, and policies left by the
  retired reconciler; it never deleted anything. Import any object you want to
  keep before the first apply.
- The personal-site Worker and the `keyboards.sammohr.dev` redirect are
  dashboard objects, not OpenTofu.

Every change: `sudo nix run .#cloudflare-plan`, review the plan, then
`sudo nix run .#cloudflare-apply`. State is root-only in
`/var/lib/cloudflare-tofu` and backed up as `CloudflareTofu`. `prevent_destroy`
guards the applications and policies; remove it deliberately if you mean to
delete them.

## Backup datasets

Datasets come from `backup.datasets` on every NixOS host.

Each dataset runs `backup-<name>.service` on its timer and writes
`/var/backup/<Name>/BACKUP-LAST-SUCCESS` after a run that verified the mirror or
found nothing to verify. A run with a prior failure marker does not refresh it.
Inspect runs with:

```sh
systemctl list-timers 'backup-*'
systemctl status backup-photos.service
journalctl -u backup-photos.service -n 100
```

A failed run leaves `BACKUP-FAILED`. The freshness timer emails when
`BACKUP-LAST-SUCCESS` is older than the dataset's limit (default 26h; weekly
datasets get 8d). The operator guide — guarantees, trigger semantics, restore,
and prune procedures — is
[`modules/features/backup/README.md`](../modules/features/backup/README.md).
Run [`drills/restore-drill.sh`](../modules/features/backup/drills/restore-drill.sh)
when changing the driver.

### CloudflareTofu

<!-- manual-step: dataset/CloudflareTofu -->

OpenTofu state for the edge objects: `/var/lib/cloudflare-tofu`, daily 00:15.
Losing state is recoverable by importing the existing objects
(`sudo nix run .#cloudflare-tofu -- import <address> <id>`), not data loss.

### GitHub

<!-- manual-step: dataset/GitHub -->

Git bare mirrors plus issue/PR metadata under `/var/lib/github-mirrors`,
nightly 00:30, local and offsite (`proton:GitHub`). Seeded on 2026-10-19; later
runs transfer deltas only. The pre-unit refreshes every repo with ghorg, then
runs `python-github-backup` incrementally into `meta/`, and fails unless the
probe repo (`sdlc`) was refreshed. It also fails on a repo-set mismatch against
`gh api user/repos`, an issue/PR count drift beyond the documented slack, a
stale pgb `last_update`, or a failed `git fsck` sample; evidence is written to
`manifests/<date>/`.

A monthly full metadata pass (`github-metadata-full.timer`, first Sunday 09:00)
rebuilds `meta` without `-i` into `meta.new`, verifies it, and swaps it in under
the host lock. Check the last result with:

```sh
systemctl status github-metadata-full.service
jq . /var/lib/github-mirrors/manifests/$(date -u +%F)/counts.json
```

Restore a repository from `/var/backup/GitHub/current/smores56_backup/<repo>`
(or `proton:GitHub`). It is a bare mirror: clone from it directly, or push it
back with `git push --mirror`. Issues, PRs, discussions, releases, and
attachments are archived JSON under `.../current/meta/repositories/<repo>/`,
not restorable state: GitHub has no issue-import that preserves numbers and
cross-references, so recreating a lost issue is a manual copy from the JSON.
The mirror token is the classic `repo`-scoped `github-repo-pat` (root-only,
0400), shared by ghorg, pgb, and the verifier; it can write to every repo the
account reaches, but these units only read.

### Music

<!-- manual-step: dataset/Music -->

`/var/lib/media/Music`, daily 05:00, offsite and change-triggered. Restore with
the drill, or:

```sh
rclone copy proton:Music /restore/Music --config /var/lib/backup/rclone.conf
```

### Photos

<!-- manual-step: dataset/Photos -->

`/var/lib/media/Photos` (the Immich library), daily 03:00, full check Sundays
06:00, change-triggered. A generated pre-unit dumps PostgreSQL as `postgres`;
the driver copies it to `current/db/immich.dump` and fails the run if the
dump is missing or stale. `thumbs` and `encoded-video` are excluded because
Immich rebuilds them from the originals.

Restore both the database dump and the library; the procedure (including
`runuser -u postgres`) is in the backup README.

### Videos

<!-- manual-step: dataset/Videos -->

`/var/lib/media/Videos`, daily 01:00, full check Sundays 07:00, offsite and
change-triggered.

## Public services

Services come from `webProxy.services` on each NixOS host. Each becomes
`<name>.<domain>` through the tunnel. Only `ssh` and `llm` have Cloudflare
Access applications (hand-written in `tofu/`); `access.enable` on any other
service fails evaluation. Calibre and Immich are public and rely on their own
app auth.

### smortress/calibre

<!-- manual-step: service/smortress/calibre -->

`calibre.sammohr.dev` → loopback `ports.calibre`, HTTP, public (no Access).
OPDS clients authenticate as `smores56` with `calibre-password`.

### smortress/immich

<!-- manual-step: service/smortress/immich -->

`immich.sammohr.dev`, public (no Access) and protected by Immich's own login.
Phones also use the LAN URL
`http://<lan-ip>:2283` (`immich.lanSources`) because Cloudflare caps a single
upload at 100 MB and Immich neither chunks nor resumes. Configure both URLs in
the mobile app.

### smortress/llm

<!-- manual-step: service/smortress/llm -->

`llm.sammohr.dev`, TCP to llama.cpp, with the service-auth policy so maki can
call it unattended. `api_key = "none"`; the tunnel and Access are the boundary.

### smortress/ssh

<!-- manual-step: service/smortress/ssh -->

`ssh.sammohr.dev`, SSH to the loopback sshd (key-only), with service auth for
`cloudflared access ssh`. `ssh` must keep Access enabled; evaluation fails
otherwise.

## Flake apps

Apps come from `modules/flake/apps.nix`. Run them as `nix run .#<name>`; from
another machine use `github:smores56/nix-config#<name>`.

### bootstrap

<!-- manual-step: app/bootstrap -->

Fresh machine (requires only Nix): clones the repo via ghq, switches
home-manager, fetches SSH public keys from Proton Pass, logs in GitHub, and on
NixOS applies the system configuration. `bootstrap.sammohr.dev` is not
provisioned by this repo; use the flake app.

### install

<!-- manual-step: app/install -->

`nix run .#install -- <host> root@<ip>`. Runs nixos-anywhere and the host's
disko layout (wiping disks), generates and writes the host's `hardware.nix`, and
delivers `secrets/hosts/<host>/` when present.

### host-key

<!-- manual-step: app/host-key -->

Generates the pre-generated host SSH key under the gitignored
`secrets/hosts/<host>/` and prints its age recipient. Add that recipient to
`.sops.yaml` as a key and as a `secrets/<host>.yaml` creation rule, then
`sops updatekeys secrets/<host>.yaml`.

### cloudflare-plan

<!-- manual-step: app/cloudflare-plan -->

`sudo nix run .#cloudflare-plan` runs a read-only plan from the root-only state
directory. Run it after any change to `tofu/` and after rotating the token.

### cloudflare-apply

<!-- manual-step: app/cloudflare-apply -->

`sudo nix run .#cloudflare-apply` applies the reviewed plan. Never apply on a
fresh state directory before importing existing objects; `prevent_destroy`
protects the applications and policies, but a wrong plan can still create
duplicates.

### cloudflare-tofu

<!-- manual-step: app/cloudflare-tofu -->

`sudo nix run .#cloudflare-tofu -- <args>` runs raw `tofu` in the state
directory, for `import`, `state list`, `state rm`, and recovery.

## Alert paths

Alert paths come from `tofu/main.tf` (notification policies) and from the
`alerting` module (`backup-freshness`, `cloudflare-email@`). All of them email
`sam@sammohr.dev` through Cloudflare Email Service; no listener runs on the
host. A Cloudflare outage silences email and the tunnel together — the console
is the fallback.

### backup-freshness

<!-- manual-step: alert/backup-freshness -->

`backup-freshness.timer` runs every five minutes and emails once per stale
period. Test it without waiting for a real lapse:

```sh
sudo touch -d '2 days ago' /var/backup/Music/BACKUP-LAST-SUCCESS
sudo systemctl start backup-freshness
sudo systemctl start backup-music   # refresh the marker
```

Delete `/run/backup-freshness/Music.alerted` to reset the once-only flag.

### unit-failure

<!-- manual-step: alert/unit-failure -->

Every backup unit's `OnFailure` starts `cloudflare-email@%n.service`, which
emails the unit's status and last 50 journal lines. Test the path without
breaking a backup:

```sh
sudo systemctl start cloudflare-email@backup-github.service
```

That sends one email about the (successful) unit; a real failure sends one per
failed run. The template reads the token from
`/run/secrets/cloudflare-api-token`.

### tunnel-health

<!-- manual-step: alert/tunnel-health -->

OpenTofu `cloudflare_notification_policy.tunnel_health` alerts on health events
for the configured tunnel. It is provider-side, so there is no local test;
confirm the policy in the dashboard after `cloudflare-apply`.

### service-token-expiry

<!-- manual-step: alert/service-token-expiry -->

OpenTofu `cloudflare_notification_policy.service_token_expiry` warns before an
Access service token expires. Renew the token in the dashboard, update the
clients that embed it (Proton Pass), and re-run `cloudflare-plan`.
