#!/usr/bin/env bash
# Exercises bootstrap.sh's scope_status. A classic OAuth token advertises its
# scopes in the `x-oauth-scopes` header; a fine-grained PAT omits the header, so
# the check must return "cannot tell" (2) rather than "missing" (1) — otherwise
# the documented fine-grained token hard-fails bootstrap.
#
# Usage: bootstrap_scopes.sh <repo-root>
set -euo pipefail

repo="${1:?usage: bootstrap_scopes.sh <repo-root>}"
bootstrap="$repo/bootstrap.sh"

# Pull just the function out so we can exercise it without running the script.
fn="$(awk '/^scope_status\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$bootstrap")"
[ -n "$fn" ] || { echo "scope_status not found in bootstrap.sh" >&2; exit 1; }
eval "$fn"

# A stub `gh` that emits the requested header, so no network is needed. It is a
# shell function (not a script) so it needs no shebang, which the Nix build
# sandbox has no /usr/bin/env for.
gh() {
  printf 'HTTP/2.0 200 OK\r\n'
  if [ -n "${STUB_SCOPES:-}" ]; then
    printf 'x-oauth-scopes: %s\r\n' "$STUB_SCOPES"
  fi
  printf '\r\n'
}

fail() { echo "FAIL: $*" >&2; exit 1; }

set +e

export STUB_SCOPES="write:public_key,write:ssh_signing_key"
scope_status "write:public_key,write:ssh_signing_key"
[ "$?" = 0 ] || fail "classic token with the required scopes should be 0"

export STUB_SCOPES="read:user"
scope_status "write:public_key"
[ "$?" = 1 ] || fail "classic token missing a scope should be 1"

unset STUB_SCOPES
scope_status "write:public_key"
[ "$?" = 2 ] || fail "no x-oauth-scopes header (fine-grained PAT) should be 2"

set -e

echo "bootstrap scope_status: ok"
