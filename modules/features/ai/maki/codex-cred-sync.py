#!/usr/bin/env python3
"""Mirror omp's active openai-codex OAuth credential into maki's token store.

maki's only OpenAI login path is device-code, which the work ChatGPT workspace
blocks. omp completes the browser PKCE flow fine, and both share the Codex
client_id (app_EMoamEEZ73f0CkXaXp7hrann) with an identical token shape, so omp's
{access,refresh,expires(ms),accountId} maps 1:1 onto maki's OAuthTokens
{access,refresh,expires,account_id} at ~/.local/state/maki/auth/openai.json.

Tolerant by design: a missing omp store or credential is a no-op (exit 0) so it
never breaks `home-manager switch`. Re-run `maki-codex-sync` after using omp if
maki's Codex calls start returning 401 (shared refresh-token drift).
"""
import json
import os
import pathlib
import sqlite3
import sys

home = os.path.expanduser("~")
src_db = pathlib.Path(home, ".omp", "agent", "agent.db")
if not src_db.exists():
    print(f"maki-codex-sync: no omp store at {src_db}; skipping")
    sys.exit(0)

con = sqlite3.connect(f"file:{src_db}?mode=ro", uri=True)
try:
    row = con.execute(
        "SELECT data FROM auth_credentials "
        "WHERE provider='openai-codex' AND credential_type='oauth' "
        "AND disabled_cause IS NULL "
        "ORDER BY updated_at DESC LIMIT 1"
    ).fetchone()
finally:
    con.close()

if not row:
    print("maki-codex-sync: no active openai-codex credential in omp; "
          "run `omp` and sign in to Codex first; skipping")
    sys.exit(0)

d = json.loads(row[0])
tokens = {
    "access": d.get("access"),
    "refresh": d.get("refresh"),
    "expires": d.get("expires"),
    "account_id": d.get("accountId"),
}
if not all(tokens[k] for k in ("access", "refresh", "expires")):
    print("maki-codex-sync: omp credential missing required fields; skipping")
    sys.exit(0)

dst_dir = pathlib.Path(home, ".local", "state", "maki", "auth")
dst_dir.mkdir(parents=True, exist_ok=True)
dst = dst_dir / "openai.json"
tmp = dst_dir / ".openai.json.tmp"
tmp.write_text(json.dumps(tokens))
os.chmod(tmp, 0o600)
os.replace(tmp, dst)
print(f"maki-codex-sync: wrote {dst} (account_id={tokens['account_id']})")
