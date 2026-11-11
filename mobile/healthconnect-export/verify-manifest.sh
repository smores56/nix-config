#!/usr/bin/env bash
# Gate for the INTERNET-less healthconnect-export fork (smores56/sdlc#593).
#
# Usage: verify-manifest.sh <fork-tree>
#
# The fork may only keep Health Connect read access plus the WorkManager/battery
# plumbing. Any network permission, Drive/webhook dependency, or leftover Drive/webhook
# code fails this check, so a rebase cannot silently reintroduce a network path.
set -euo pipefail

tree=${1:?usage: verify-manifest.sh <fork-tree>}
manifest="$tree/app/src/main/AndroidManifest.xml"
main="$tree/app/src/main"
gradle=""
for candidate in "$tree/app/build.gradle.kts" "$tree/app/build.gradle"; do
  if [[ -f "$candidate" ]]; then
    gradle="$candidate"
    break
  fi
done

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok: $*"; }

[[ -f "$manifest" ]] || { echo "missing $manifest" >&2; exit 2; }
[[ -n "$gradle" ]] || { echo "missing app/build.gradle(.kts) under $tree" >&2; exit 2; }
[[ -d "$main" ]] || { echo "missing $main" >&2; exit 2; }

# 1. Network permissions must be gone.
for permission in \
  INTERNET \
  ACCESS_NETWORK_STATE \
  ACCESS_WIFI_STATE \
  CHANGE_NETWORK_STATE \
  CHANGE_WIFI_STATE \
  BLUETOOTH \
  BLUETOOTH_ADMIN \
  BLUETOOTH_SCAN \
  BLUETOOTH_CONNECT \
  NEARBY_WIFI_DEVICES \
  NFC; do
  if grep -q "android.permission.${permission}\"" "$manifest"; then
    err "AndroidManifest.xml still declares android.permission.${permission}"
  fi
done
ok "no network or Bluetooth permissions"

# 2. The features that must survive.
for permission in \
  FOREGROUND_SERVICE \
  FOREGROUND_SERVICE_DATA_SYNC \
  RECEIVE_BOOT_COMPLETED \
  REQUEST_IGNORE_BATTERY_OPTIMIZATIONS; do
  grep -q "android.permission.${permission}\"" "$manifest" \
    || err "AndroidManifest.xml lost android.permission.${permission}"
done
grep -q 'android.permission.health.READ_' "$manifest" \
  || err "AndroidManifest.xml has no Health Connect read permission"
ok "Health Connect read, foreground service, boot and battery permissions remain"

# 3. No network dependency may remain in the build file.
for dependency in \
  google-api-services-drive \
  google-api-client \
  google-http-client \
  play-services-auth \
  credentials-play-services-auth \
  googleid \
  okhttp \
  retrofit; do
  if grep -q "$dependency" "$gradle"; then
    err "$(basename "$gradle") still depends on $dependency"
  fi
done
if grep -q 'GOOGLE_CLIENT_ID' "$gradle"; then
  err "$(basename "$gradle") still bakes in GOOGLE_CLIENT_ID"
fi
ok "no Drive, Google auth or HTTP client dependency"

# 4. No Drive/webhook code or identifiers.
while IFS= read -r -d '' file; do
  case "$(basename "$file")" in
    *Drive*.kt | *Webhook*.kt) err "Drive/webhook source remains: ${file#"$tree"/}" ;;
  esac
done < <(find "$main" -type f -name '*.kt' -print0)
matches=$(grep -rIl --include='*.kt' -E 'GoogleDriveRepository|WebhookRepository|DriveManager|WebhookManager|autoSyncDrive|webhookUrl|webhookAuthToken|OkHttpClient|HttpURLConnection|drive\.google|googleapis\.com' "$main" || true)
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches" >&2
  err "Drive/webhook code or endpoints remain under app/src/main"
fi
if grep -q 'WatchdogAlarmReceiver' "$manifest"; then
  err "AndroidManifest.xml still registers the Drive delivery watchdog"
fi
ok "no Drive or webhook code"

# 5. The surviving export path must still be scheduled and exempt.
worker=$(find "$main" -name 'DailyExportWorker.kt' -print -quit)
[[ -n "$worker" ]] || err "DailyExportWorker.kt is missing"
if [[ -n "$worker" ]] && ! grep -q 'PeriodicWorkRequestBuilder' "$worker"; then
  err "DailyExportWorker.kt no longer schedules periodic work"
fi
battery=$(find "$main" -name 'BatteryOptimization.kt' -print -quit)
[[ -n "$battery" ]] || err "BatteryOptimization.kt is missing"
if [[ -n "$battery" ]] && ! grep -q 'ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS' "$battery"; then
  err "BatteryOptimization.kt lost the exemption request"
fi
ok "WorkManager daily export and battery exemption remain"

exit "$fail"
