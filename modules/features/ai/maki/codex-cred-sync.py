#!/usr/bin/env python3
"""Mirror Codex CLI OAuth credentials into maki's token store.

maki's OpenAI login path is device-code, which the work ChatGPT workspace
blocks. The standard Codex browser login works and shares the same OAuth client
id (app_EMoamEEZ73f0CkXaXp7hrann), so Codex's
{access_token,refresh_token,account_id} maps onto maki's OAuthTokens
{access,refresh,expires,account_id} at ~/.local/state/maki/auth/openai.json.

Tolerant by design: a missing Codex auth file or non-ChatGPT login is a no-op
(exit 0) so it never breaks `home-manager switch`. Re-run `maki-codex-sync`
after `codex login` or if maki's Codex calls start returning 401.
"""
import base64
import json
import os
import pathlib
import sys
import tempfile


def jwt_exp_ms(token):
    parts = token.split(".")
    if len(parts) != 3:
        return None
    payload = parts[1]
    payload += "=" * ((4 - len(payload) % 4) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError):
        return None
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)):
        return None
    return int(exp * 1000)


def write_private_json(dst, data):
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".openai.", suffix=".tmp", dir=dst.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
            f.write("\n")
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, dst)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


home = os.path.expanduser("~")
src = pathlib.Path(home, ".codex", "auth.json")
if not src.exists():
    print(
        f"maki-codex-sync: no Codex auth file at {src}; "
        "run `codex login`; skipping"
    )
    sys.exit(0)

try:
    auth = json.loads(src.read_text())
except (OSError, json.JSONDecodeError) as e:
    print(f"maki-codex-sync: cannot read Codex auth file: {e}; skipping")
    sys.exit(0)

if auth.get("auth_mode") != "chatgpt":
    print(
        "maki-codex-sync: Codex is not using ChatGPT auth; "
        "run `codex login`; skipping"
    )
    sys.exit(0)

codex_tokens = auth.get("tokens") or {}
access = codex_tokens.get("access_token")
refresh = codex_tokens.get("refresh_token")
expires = jwt_exp_ms(access or "")
tokens = {
    "access": access,
    "refresh": refresh,
    "expires": expires,
    "account_id": codex_tokens.get("account_id"),
}
if not all(tokens[k] for k in ("access", "refresh", "expires")):
    print("maki-codex-sync: Codex auth missing required OAuth fields; skipping")
    sys.exit(0)

dst = pathlib.Path(home, ".local", "state", "maki", "auth", "openai.json")
write_private_json(dst, tokens)
account = "present" if tokens.get("account_id") else "absent"
print(f"maki-codex-sync: wrote {dst} (account_id={account})")
