#!/usr/bin/env bash
# Keep docs/manual-steps.md in sync with the configuration it documents.
#
# Expected inventory: hosts from modules/hosts, secret names from the encrypted
# sops files, providers and notification policies from tofu/, and the
# config-derived datasets/services/apps/alerts passed as JSON by checks.nix.
set -euo pipefail

src=${1:?usage: manual_steps_sync.sh <repo> <inventory.json>}
inventory=${2:?usage: manual_steps_sync.sh <repo> <inventory.json>}
doc="$src/docs/manual-steps.md"
fail=0

if [[ ! -f "$doc" ]]; then
  echo "missing manual-steps document: $doc" >&2
  exit 1
fi

declare -A expected=() found=()

add_expected() { expected["$1"]=1; }

for dir in "$src"/modules/hosts/*/; do
  add_expected "host/$(basename "$dir")"
done

# sops encrypts values, not key names, so the top-level names are readable.
while IFS= read -r key; do
  add_expected "secret/$key"
done < <(sed -n 's/^\([A-Za-z0-9._-]*\):.*/\1/p' "$src"/secrets/*.yaml | grep -vx sops | sort -u)

while IFS= read -r provider; do
  add_expected "provider/$provider"
done < <(sed -n 's/^[[:space:]]*source[[:space:]]*=[[:space:]]*"\([^/"]*\)\/.*/\1/p' "$src"/tofu/*.tf | sort -u)

while IFS= read -r name; do
  add_expected "alert/${name//_/-}"
done < <(sed -n 's/^resource "cloudflare_notification_policy" "\([^"]*\)".*/\1/p' "$src"/tofu/*.tf)

while IFS= read -r item; do add_expected "dataset/$item"; done < <(jq -r '.datasets[]' "$inventory")
while IFS= read -r item; do add_expected "service/$item"; done < <(jq -r '.services[]' "$inventory")
while IFS= read -r item; do add_expected "app/$item"; done < <(jq -r '.apps[]' "$inventory")
while IFS= read -r item; do add_expected "alert/$item"; done < <(jq -r '.alerts[]' "$inventory")

while IFS= read -r anchor; do
  if [[ -n "${found[$anchor]:-}" ]]; then
    echo "duplicate anchor: $anchor" >&2
    fail=1
  fi
  found["$anchor"]=1
done < <(grep -o '<!-- manual-step: [a-z]*/[^ ]* -->' "$doc" | sed 's/^<!-- manual-step: //; s/ -->$//')

missing=$(comm -23 <(printf '%s\n' "${!expected[@]}" | sort) <(printf '%s\n' "${!found[@]}" | sort))
stale=$(comm -13 <(printf '%s\n' "${!expected[@]}" | sort) <(printf '%s\n' "${!found[@]}" | sort))

if [[ -n "$missing" ]]; then
  echo "manual-steps.md is missing anchors for:" >&2
  printf '%s\n' "$missing" | sed 's/^/  /' >&2
  fail=1
fi

if [[ -n "$stale" ]]; then
  echo "manual-steps.md documents items that no longer exist:" >&2
  printf '%s\n' "$stale" | sed 's/^/  /' >&2
  fail=1
fi

if grep -nE '\b(TODO|TBD)\b' "$doc"; then
  echo "manual-steps.md contains unresolved TODO/TBD markers" >&2
  fail=1
fi

exit "$fail"
