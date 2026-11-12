# ingest-immich: photo metadata

The `ingest-immich` guest reads the Immich library's **metadata only**: asset
fields, EXIF, places, people and album membership. It never requests image,
thumbnail, video or archive bytes, and it can reach exactly one name through the
host proxy: `photos.sammohr.dev`.

Module: `modules/nixos/ingest-vm.nix` (guest block `lib.mkIf (id == "immich")`).
Table entry: `modules/lib/ingest-vm.nix`. Tool:
`modules/lib/ingest/immich.py`. Tests: `tests/test_ingest_immich.py`.

## API key (one-time, human)

Create a dedicated key in Immich (Account Settings → API Keys) with exactly
these permissions:

| permission | why |
|---|---|
| `asset.read` | asset metadata, EXIF, search |
| `album.read` | album list and album membership |
| `person.read` | named and hidden people |

Grant nothing else: no `asset.write`, `album.write`, `person.write`, no download
or share permissions. The key is a bearer credential; it lives only in
`/run/secrets/ingest-immich-env` and is redacted from every log line and error.

### Secret contract

`/run/ingest-secret/env` accepts exactly:

| key | required | meaning |
|---|---|---|
| `IMMICH_API_KEY` | yes | scoped read-only key |
| `IMMICH_BASE_URL` | no | must be `https://photos.sammohr.dev` (the default) |
| `IMMICH_PAGE_SIZE` | no | 1..1000, default 250 in the request, 1000 in this collector |

A URL with another host, a path, HTTP, userinfo or a query is refused before any
request; the guest cannot be pointed at another cluster service by editing its
own contract.

## One egress flow

```
ingest-immich (10.77.13.2) → host proxy 10.77.13.1:3128 → https://photos.sammohr.dev:443
                              host resolver 10.77.13.1:53 (exact name only)
```

There is no direct nftables flow from the guest to the cluster. The per-tap
forward chain has no ACCEPT other than conntrack and ends in DROP; the input
chain admits only the proxy and resolver; the resolver answers A/AAAA for
`photos.sammohr.dev` and REFUSES every other name. No cluster address, pod IP,
service IP or LAN range is reachable, and `kanbei-ingest-guards` fails
evaluation if the table's allowlist is widened. The proxy also requires the TLS
SNI to equal the CONNECT host, so a compromised guest cannot tunnel to another
service through the same allowance.

This replaces the design note's direct `ingest-immich` → cluster-port rule: the
T14 plane puts every source behind the host's hostname/SNI proxy, one name per
source. The Immich app still listens on its cluster port (2283); the guest never
addresses that port or a cluster IP, only `photos.sammohr.dev:443` through the
tunnel and proxy, so the destination is the same Immich service while the
enforcement point is the host, not a cluster-side nftables rule.

## Endpoints and pagination

The client has a three-endpoint allowlist and refuses every other path before a
socket is opened:

| method | path | use |
|---|---|---|
| `POST` | `/api/search/metadata` | asset pages and album membership |
| `GET` | `/api/albums` | album list |
| `GET` | `/api/people?page=&size=&withHidden=` | people pages |

Refused explicitly (and covered by tests): `/api/assets…`,
`/api/assets/<id>/original`, `…/thumbnail`, `/api/download`, `/api/videos…`,
`/api/server/…` and any query on an endpoint that does not take one. Responses
must be `application/json` and are capped at 16 MiB; a non-JSON content type
(an image) fails the unit instead of being parsed.

Asset pages are requested with `withExif`, `withPeople`, `order: asc` and
`updatedAfter` set to the stored cursor. The loop follows `nextCursor` (v3) or
`nextPage` (v1/v2) while either token is present and stops when the server sends
`null`, with a page cap so a broken server cannot loop forever. Album
membership uses `filter.albumIds.ids`, 500 ids per item.

## Items

| item | fields |
|---|---|
| `immich-asset` | id, kind, original file name, MIME, taken/created/updated timestamps, width, height, duration, favorite/archived/trashed/visibility, duplicate/live-photo/stack ids, people names, tag values, EXIF subset |
| `immich-album` | id, name, description, asset count, shared, created/updated, start/end dates |
| `immich-album-assets` | album id and up to 500 asset ids |
| `immich-person` | id, name, birth date, hidden/favorite, updated |
| `immich-removed` | kind (`album`/`person`) and id |

The EXIF subset is `make`, `model`, `lensModel`, `iso`, `fNumber`,
`exposureTime`, `focalLength`, latitude/longitude, city/state/country,
`dateTimeOriginal`, `timeZone` and `rating`. Deliberately absent: `thumbhash`
(a pixel placeholder), `originalPath`, checksums and owner ids.

## Cursor and dedupe

State lives in `/var/lib/immich/state.json` (`0600`):

- `assets` is `{updated_at,id}`, the last emitted `(updatedAt, id)`. The first
  run has an empty cursor and therefore pages the whole library once; later runs
  send `updatedAfter` and re-filter the boundary page client-side, so a restart
  at the same timestamp does not replay.
- `albums` and `people` keep each object's `updatedAt` (people also the name).
  Album membership is fetched only for a changed album, and a fetch failure
  leaves the stored `updatedAt` in place so it retries next run.
- Full album and people lists detect deletions; asset deletions are not
  detectable from this API surface, so a trashed asset is carried with
  `is_trashed: true` rather than removed.
- Batches are written atomically to `/var/lib/ingest/outbox`, 200 items / 350
  KiB each, with the shared envelope (`source: immich`). Kanbei dedupes on the
  asset id and `updatedAt`; the protocol is at-least-once.

## Units and limits

| unit | purpose |
|---|---|
| `ingest-immich.service` | one metadata pass: assets, albums, people |
| `ingest-immich.timer` | every 6 h at 03:23/09:23/15:23/21:23 with 15 min jitter, `Persistent=true` |

`MemoryHigh=80M`, `MemoryMax=112M`; the guest is 128 MiB. The table's 6 h window
matches the timer: two missed passes are silent, three page. No image bytes are
ever transferred, so the guest's memory and disk stay proportional to the
metadata, not the library.

## Verification

```sh
nix build .#checks.x86_64-linux.unit-tests .#checks.x86_64-linux.kanbei-ingest-guards
nix eval .#nixosConfigurations.smortress --apply 'c: (c.extendModules { modules = [ ({ lib, ... }: { ingestVm.enable = lib.mkForce true; kanbeiVm.enable = lib.mkForce true; }) ]; }).config.microvm.vms.ingest-immich.config.config.system.build.toplevel.drvPath'
```

Hardware/credential gated (root on smortress, a scoped key):

1. Create the key with the three read permissions, stage
   `ingest-immich-env`, and start `microvm@ingest-immich`; check
   `systemctl status ingest-immich` in the guest.
2. Confirm the first run pages the whole library once and later runs emit only
   changed assets/albums/people (`journalctl -u ingest-immich` shows counts).
3. Confirm `immich-*.age` batches appear in `/var/lib/data/inbox` and Kanbei
   shows names, places, albums and people, with no image data.
4. Prove the egress scope from the guest: `photos.sammohr.dev` resolves, every
   other name is REFUSED, `1.1.1.1` is unreachable, and a curl to
   `/api/assets/<id>/original` is refused by the client before dialling.
