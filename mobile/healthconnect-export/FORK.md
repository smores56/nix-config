# healthconnect-export fork

Upstream: <https://github.com/nachojrs/healthconnect-export>
Audited commit: `e33563e29b387c32d331215725dae46d1bebd6a2` (2026-10-05, version 1.10,
versionCode 14, `main`). `source.nix` pins that rev; `fork.patch` applies on top of it.

The upstream app is a Health Connect exporter that can also upload to Google Drive and
POST to a webhook. The kanbei pipeline needs the exporter and nothing that can reach the
network, so the fork removes both features and the manifest permissions/dependencies that
made them possible. The only sink is the local SAF directory the operator points at the
phone's Syncthing folder.

## What the patch changes

Removed (Drive):

- `app/src/main/java/com/healthconnect/export/auth/` (`GoogleAuthProvider`,
  `DriveSessionStore`)
- `repository/GoogleDriveRepository.kt`, `viewmodel/DriveManager.kt`,
  `ui/components/DriveStatusCard.kt`
- Google Sign-In, Credential Manager, Google HTTP/API client and Drive dependencies from
  `app/build.gradle.kts`, plus the baked-in `GOOGLE_CLIENT_ID`

Removed (webhook):

- `repository/WebhookRepository.kt`, `viewmodel/WebhookManager.kt`,
  `worker/CatchUpWebhookWorker.kt`, `worker/Every2HoursWebhookWorker.kt`,
  `ui/components/WebhookCard.kt`
- the webhook fields in `ExportConfig` and the persisted webhook settings

Removed (delivery watchdog, whose only job was to keep Drive/webhook delivery alive):

- `worker/DeliveryWatchdog.kt`, `receiver/WatchdogAlarmReceiver.kt`,
  `util/DeliveryLog.kt`, and their manifest receiver/Java package references

Replaced:

- `MainActivity.kt` is a four-action setup screen: grant Health Connect read access, pick
  the Syncthing folder with the Storage Access Framework, request the battery-optimisation
  exemption, and show the result. No account, upload or webhook UI.
- `viewmodel/ExportViewModel.kt`, `viewmodel/ScheduleManager.kt` and the Compose `ui/`
  package are deleted; scheduling lives in `DailyExportWorker.schedule` (WorkManager,
  daily, `ExistingPeriodicWorkPolicy.UPDATE`) and the boot receiver re-enqueues it.
- `LocalExportRepository` writes into the persisted SAF tree (`DocumentsContract` via
  `DocumentFile`) when the operator picked one, with the app's external files directory as
  the fallback. This is required because Android 11+ hides `Android/data/<package>` from
  other apps, so Syncthing cannot read the fallback path.

Manifest after the patch: no `INTERNET`, `ACCESS_NETWORK_STATE`, Wi-Fi, Bluetooth or NFC
permission; the Health Connect `READ_*` set, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_DATA_SYNC`, `RECEIVE_BOOT_COMPLETED` and
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` remain. `verify-manifest.sh` enforces both sides.

Tests for the deleted features are deleted with them; the remaining unit tests
(`LocalExportRepository`, `ExportSettings`, serialization, Health Connect repository,
battery, locale, foreground notifier) are updated for the new `ExportConfig` and settings.

## Build and sideload

The Android SDK and the release keystore are operator-held; this repo does not build the
app.

```sh
git clone https://github.com/nachojrs/healthconnect-export
cd healthconnect-export
git checkout e33563e29b387c32d331215725dae46d1bebd6a2
git apply /path/to/nix-config/mobile/healthconnect-export/fork.patch
bash /path/to/nix-config/mobile/healthconnect-export/verify-manifest.sh .
./gradlew :app:assembleRelease        # or assembleDebug for a test install
adb install -r app/build/outputs/apk/release/app-release.apk
```

`verify-manifest.sh` must print `ok` for every section before installing. After a
sideload, open the app once: grant all Health Connect read permissions, choose the
Syncthing folder as the export directory (the `phone` folder root; the app writes
`health/health_<date>.json`), and allow background execution
(`docs/kanbei-phone.md`).

## Output contract

`health_<YYYY-MM-DD>.json` inside the chosen tree's `health/` subdirectory. The payload is
upstream's `DailyHealthRecord`: `date`, optional per-type aggregates (`steps`,
`heart_rate`, `sleep`, `calories`, …) and `metadata` with `app_version`,
`export_timestamp`, `timezone` and `source_device`. The decrypt service validates the
filename, caps the file at 16 MiB and hashes the content for dedupe.
