# slack-mcp-auth: set up Slack session tokens for slack-mcp-server (pi MCP).
#
# Auto-extracts xoxc (leveldb) and xoxd (encrypted cookie) from the Slack
# desktop app, validates them against auth.test, and upserts them into
# ~/.config/fish/conf.d/api-keys.fish where pi-mcp-adapter's ${ENV_VAR}
# interpolation picks them up. Falls back to manual paste if extraction
# fails. Re-run whenever the Slack session (and thus the tokens) expires.
#
# Wrapped by pkgs.writeShellScriptBin in modules/features/ai/pi/default.nix.
set -euo pipefail

SLACK_DIR="$HOME/Library/Application Support/Slack"
OUT_FILE="$HOME/.config/fish/conf.d/api-keys.fish"

note() { printf '[slack-mcp-auth] %s\n' "$*"; }
err() { printf '[slack-mcp-auth] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# xoxd: decrypt the 'd' cookie from Slack desktop's Chromium cookie store.
# Key derivation: PBKDF2-SHA1("Slack Safe Storage" keychain pw, "saltysalt",
# 1003 iters, 16 bytes); AES-128-CBC with IV of 16 spaces. Newer Chromium
# prepends SHA256(host_key) (32 bytes) to the plaintext.
# ---------------------------------------------------------------------------
extract_xoxd() {
  python3 - "$SLACK_DIR/Cookies" <<'PYEOF'
import hashlib, os, shutil, sqlite3, subprocess, sys, tempfile

cookie_db = sys.argv[1]
if not os.path.exists(cookie_db):
    sys.exit(1)

# Copy first: the live DB may be locked while Slack is running.
fd, tmp = tempfile.mkstemp(suffix=".sqlite")
os.close(fd)
try:
    shutil.copyfile(cookie_db, tmp)
    con = sqlite3.connect(tmp)
    row = con.execute(
        "SELECT value, encrypted_value FROM cookies "
        "WHERE name = 'd' AND host_key LIKE '%slack.com' "
        "ORDER BY LENGTH(encrypted_value) DESC LIMIT 1"
    ).fetchone()
    con.close()
finally:
    os.unlink(tmp)

if row is None:
    sys.exit(1)
value, enc = row
if value and value.startswith("xoxd-"):
    print(value)
    sys.exit(0)
enc = bytes(enc or b"")
if not enc.startswith(b"v10"):
    sys.exit(1)

password = subprocess.run(
    ["security", "find-generic-password", "-w", "-s", "Slack Safe Storage"],
    capture_output=True, text=True, check=True,
).stdout.strip()
key = hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1003, 16)
plain = subprocess.run(
    ["openssl", "enc", "-d", "-aes-128-cbc", "-K", key.hex(), "-iv", "20" * 16],
    input=enc[3:], capture_output=True, check=True,
).stdout
if not plain.startswith(b"xoxd-") and len(plain) > 32:
    plain = plain[32:]  # strip SHA256(host_key) prefix (Chromium >= 24)
token = plain.decode("utf-8", "ignore").strip()
if not token.startswith("xoxd-"):
    sys.exit(1)
print(token)
PYEOF
}

# ---------------------------------------------------------------------------
# xoxc: scrape workspace tokens out of Slack desktop's leveldb localStorage.
# May yield several (one per signed-in workspace); each is validated below.
# ---------------------------------------------------------------------------
extract_xoxc_candidates() {
  local lsdir="$SLACK_DIR/Local Storage/leveldb"
  [ -d "$lsdir" ] || return 1
  grep -aoh 'xoxc-[0-9A-Za-z-]\{20,\}' "$lsdir"/*.log "$lsdir"/*.ldb 2>/dev/null | sort -u
}

# auth_test XOXC XOXD -> prints "team<TAB>user" on success, fails otherwise
auth_test() {
  curl -s --max-time 10 https://slack.com/api/auth.test \
    -H "Authorization: Bearer $1" \
    -H "Cookie: d=$2" \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    sys.exit(1)
print(d.get("team", "?") + "\t" + d.get("user", "?"))
'
}

prompt_token() { # $1=name $2=prefix -> echoes token
  local token
  while true; do
    read -r -p "Paste $1 token ($2...): " token
    case "$token" in
      "$2"*) printf '%s\n' "$token"; return 0 ;;
      *) err "doesn't start with $2, try again" ;;
    esac
  done
}

write_tokens() { # $1=xoxc $2=xoxd
  mkdir -p "$(dirname "$OUT_FILE")"
  touch "$OUT_FILE"
  local tmp
  tmp=$(mktemp)
  grep -v '^set -gx SLACK_MCP_XOX[CD]_TOKEN ' "$OUT_FILE" > "$tmp" || true
  {
    cat "$tmp"
    printf 'set -gx SLACK_MCP_XOXC_TOKEN %s\n' "$1"
    printf 'set -gx SLACK_MCP_XOXD_TOKEN %s\n' "$2"
  } > "$OUT_FILE"
  rm -f "$tmp"
  chmod 600 "$OUT_FILE"
}

# --- xoxd ------------------------------------------------------------------
XOXD=""
if XOXD=$(extract_xoxd); then
  note "extracted xoxd cookie from Slack.app"
else
  err "couldn't auto-extract the xoxd cookie from Slack.app"
  err "manual route: browser DevTools on app.slack.com -> Application -> Cookies -> 'd' (URL-decoded)"
  XOXD=$(prompt_token xoxd xoxd-)
fi

# --- xoxc ------------------------------------------------------------------
declare -a VALID_TOKENS=() VALID_LABELS=()
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if label=$(auth_test "$candidate" "$XOXD"); then
    VALID_TOKENS+=("$candidate")
    VALID_LABELS+=("$label")
  fi
done < <(extract_xoxc_candidates || true)

XOXC=""
case "${#VALID_TOKENS[@]}" in
  0)
    err "no working xoxc token found in Slack.app's local storage"
    err "manual route: DevTools console on app.slack.com:"
    err '  JSON.parse(localStorage.localConfig_v2).teams[document.location.pathname.match(/^\/client\/([A-Z0-9]+)/)[1]].token'
    XOXC=$(prompt_token xoxc xoxc-)
    if ! label=$(auth_test "$XOXC" "$XOXD"); then
      err "auth.test failed for pasted token + extracted cookie; aborting"
      exit 1
    fi
    note "validated: $label"
    ;;
  1)
    XOXC="${VALID_TOKENS[0]}"
    note "validated workspace: ${VALID_LABELS[0]}"
    ;;
  *)
    note "multiple workspaces found:"
    for i in "${!VALID_TOKENS[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${VALID_LABELS[$i]}"
    done
    read -r -p "Use which? [1-${#VALID_TOKENS[@]}]: " choice
    XOXC="${VALID_TOKENS[$((choice - 1))]}"
    ;;
esac

# --- persist ---------------------------------------------------------------
write_tokens "$XOXC" "$XOXD"
note "wrote SLACK_MCP_XOXC_TOKEN / SLACK_MCP_XOXD_TOKEN to $OUT_FILE (mode 600)"
note "restart your shell (or 'exec fish') and restart pi to pick them up"
