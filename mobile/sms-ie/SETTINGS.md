# SMS Import / Export settings

App: <https://github.com/tmo1/sms-ie> (`com.github.tmo1.sms_ie`), audited release
`v2.12.0` (2026-10-09). The `standard` flavor is the only one to install (API ≥ 24).
Settings below are the exact `SharedPreferences` keys from the app's
`app/src/main/res/xml/root_preferences.xml`, so they can be re-checked after an app
update.

SMS Import / Export writes its scheduled export to one directory. On the phone that is
the Syncthing folder's `sms/` subdirectory; `contacts-*.json` lands there too because the
app has no per-type directory setting. The kanbei guest routes contacts files into
`contacts/` on decrypt, so the canonical tree on the Kanbei side is
`sms/`, `contacts/`, `health/` (`modules/lib/phone-pipeline.nix`).

## Scheduled export

| Key | Value | Why |
|---|---|---|
| `schedule_export` | on | daily headless export |
| `export_time` | `02:30` | finished before the 03:30 host backup; Syncthing runs continuously |
| `export_interval_days` | `1` | one datestamped set per day |
| `export_dir` | `<Syncthing folder>/sms` | the `phone` folder the host receives encrypted |
| `export_messages` | on | SMS and MMS (v2 NDJSON ZIP) |
| `export_calls` | on | call log JSON |
| `export_contacts` | on | contacts JSON (experimental upstream; validated on ingest) |
| `export_success_notification` | on | a silent missing-export signal; the heartbeat is the machine check |
| `delete_old_exports` | off | Kanbei's LUKS volume is the archive; the phone never prunes it |
| `remove_datestamps_from_filenames` | off | datestamped names are the dedupe key |

The format is fixed by the app version: **v2** for messages (`messages.ndjson` inside a
ZIP with the `data/` MMS binary directory), JSON for call log and contacts.

## Data toggles

| Key | Value |
|---|---|
| `include_binary_data` | off (`include_binary_data=false`) |
| `include_blobs` | off |
| `store_media_uncompressed` | off (only meaningful with binary data on) |
| `deduplication` | off (import-only feature) |

Binary MMS data and MMS-table BLOBs are not exported: they bloat a day's export past the
16 MiB per-file cap and are not needed for the text/call/contact pipeline. MMS *metadata*
(subject, addresses, timestamps, parts manifest) is still exported. Turn
`include_binary_data` back on only together with a larger
`phone.maxFileBytes` and an ingest review.

## Android battery settings

- The app's WorkManager job is deferred under Doze without an exemption. The setting row
  `disable_battery_optimizations` is Android's
  `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog; grant it.
- Grant the same exemption to Syncthing-Fork (`com.github.catfriend1.syncthingfork`).
- Some OEM ROMs (MIUI, EMUI) additionally need "Autostart" and "no battery restriction"
  per app; the stock Android setting is not enough there.

## Blocked numbers

Scheduled export of blocked numbers is **not** implemented upstream: the
`BlockedNumberContract` requires the app to be the default SMS or phone app, and switching
default apps needs manual intervention. The scheduled run therefore carries SMS, MMS, call
log and contacts only. A one-off blocked-numbers export is possible by temporarily making
the app the default phone/SMS app and exporting manually, then restoring the real
defaults; the blocked list is not part of the daily pipeline and the heartbeat does not
cover it.

## Verification

`validate-export.py` checks the schema of a sample export before it is trusted as the
contract:

```sh
python3 mobile/sms-ie/validate-export.py <export-directory-or-file>
```

It validates `messages.ndjson` inside the ZIP, `calls-*.json` and `contacts-*.json`
(fixtures under `mobile/sms-ie/fixtures/`). The guest repeats the filename and size checks
on every decrypt; the validator is the development-time check for a new app version.
