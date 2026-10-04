#!/usr/bin/env python3
"""Reconcile Cloudflare DNS and Access for the tunnel-exposed services declared
in `dotfiles.webProxy.services`.

Nix emits a secrets-free desired-state JSON (see `modules/nixos/cloudflare-sync.nix`)
and the API token is read at runtime from a 0600 file, so no secret ever enters
the Nix store. The reconciler is additive for DNS: it creates a proxied CNAME
for each declared subdomain and adopts an existing matching record, but never
deletes one — an orphan that points at the tunnel without ingress simply hits
the 404 default. Access applications are the exception: disabling Access (or
removing the entry) deletes the app, so turning it off genuinely makes the
endpoint public.

The tunnel UUID is never authored: it is read out of the tunnel credentials
file's `TunnelID` at runtime and used to build `<uuid>.cfargotunnel.com`.

`--check` prints the diff, mutates nothing, and exits non-zero when drift
exists, so CI or a rebuild can detect a dashboard edit that the next apply
would revert. Exit codes: 0 clean, 1 drift, 2 an API or spec error (so a
permission problem is never mistaken for drift).
"""

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import namedtuple

API_BASE = "https://api.cloudflare.com/client/v4"
DEFAULT_TOKEN_FILE = "/var/lib/cloudflare/api-token"
# Stable path the module installs the Nix-emitted spec at, so `cloudflare-sync
# --check` works without the caller knowing a /nix/store path.
DEFAULT_SPEC_FILE = "/etc/cloudflare-sync/spec.json"
SESSION_DURATION = "24h"
TUNNEL_SUFFIX = ".cfargotunnel.com"
# Actions that mean the live state differs from the desired state.
DRIFT_ACTIONS = frozenset({"created", "updated", "deleted"})

Result = namedtuple("Result", ["action", "detail"])


class CloudflareError(Exception):
    pass


def read_token(path):
    try:
        with open(path) as handle:
            token = handle.read().strip()
    except OSError as exc:
        raise CloudflareError(f"cannot read API token {path}: {exc}") from exc
    if not token:
        raise CloudflareError(f"API token file {path} is empty")
    return token


def read_tunnel_id(path):
    try:
        with open(path) as handle:
            credentials = json.load(handle)
    except (OSError, ValueError) as exc:
        raise CloudflareError(f"cannot read tunnel credentials {path}: {exc}") from exc
    tunnel_id = credentials.get("TunnelID")
    if not tunnel_id:
        raise CloudflareError(f"tunnel credentials {path} carry no TunnelID")
    return tunnel_id


class CloudflareClient:
    """Thin JSON client over the Cloudflare API, stdlib only."""

    def __init__(self, token, base=API_BASE):
        self.token = token
        self.base = base

    def _request(self, method, path, params=None, body=None):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            hint = ""
            if exc.code in (401, 403):
                hint = (
                    " (token is missing a required scope: needs Zone:DNS:Write and "
                    "Access: Apps and Policies:Write; reading the zone also needs "
                    "Zone:Read and fails earlier at GET /zones)"
                )
            raise CloudflareError(
                f"{method} {path} -> HTTP {exc.code}: {detail}{hint}"
            ) from exc
        except urllib.error.URLError as exc:
            raise CloudflareError(f"{method} {path} -> {exc.reason}") from exc
        if not payload.get("success"):
            raise CloudflareError(f"{method} {path} -> {payload.get('errors')}")
        return payload

    def _result(self, method, path, params=None, body=None):
        return self._request(method, path, params=params, body=body)["result"]

    def get(self, path, params=None):
        return self._result("GET", path, params=params)

    def paginate(self, path, params=None):
        """Follow result_info.total_pages so >100 objects are all seen."""
        items = []
        page = 1
        while True:
            query = dict(params or {})
            query["page"] = page
            payload = self._request("GET", path, params=query)
            items.extend(payload.get("result") or [])
            info = payload.get("result_info") or {}
            if page >= info.get("total_pages", 1):
                return items
            page += 1

    def post(self, path, body):
        return self._result("POST", path, body=body)

    def put(self, path, body):
        return self._result("PUT", path, body=body)

    def delete(self, path):
        return self._result("DELETE", path)


def resolve_account(client, zone):
    zones = client.get("/zones", params={"name": zone})
    if not zones:
        raise CloudflareError(
            f"zone {zone!r} not found; is the API token scoped to it? "
            "(needs Zone:DNS:Write and Access: Apps and Policies:Write)"
        )
    return zones[0]["id"], zones[0]["account"]["id"]


def _dns_body(name, content):
    return {"type": "CNAME", "name": name, "content": content, "proxied": True, "ttl": 1}


def reconcile_dns(client, zone_id, fqdn, tunnel_id, dry_run):
    content = tunnel_id + TUNNEL_SUFFIX
    records = client.paginate(
        f"/zones/{zone_id}/dns_records", params={"type": "CNAME", "name": fqdn}
    )
    if not records:
        if not dry_run:
            client.post(f"/zones/{zone_id}/dns_records", _dns_body(fqdn, content))
        return [Result("created", f"DNS {fqdn} -> {content}")]
    record = records[0]
    if record.get("content") == content and record.get("proxied"):
        return [Result("adopted", f"DNS {fqdn} -> {content}")]
    if not dry_run:
        client.put(
            f"/zones/{zone_id}/dns_records/{record['id']}", _dns_body(fqdn, content)
        )
    return [Result("updated", f"DNS {fqdn} -> {content} (was {record.get('content')})")]


def reconcile_access(client, account_id, fqdn, email, wanted, dry_run):
    apps = [
        app
        for app in client.paginate(
            f"/accounts/{account_id}/access/apps", params={"per_page": 100}
        )
        if app.get("domain") == fqdn
    ]

    if not wanted:
        if not apps:
            return [Result("unchanged", f"Access {fqdn}: off")]
        if not dry_run:
            client.delete(f"/accounts/{account_id}/access/apps/{apps[0]['id']}")
        return [Result("deleted", f"Access app {fqdn}")]

    results = []
    policy_name = f"allow {email}"
    policies = client.paginate(
        f"/accounts/{account_id}/access/policies", params={"per_page": 100}
    )
    policy = next((p for p in policies if p.get("name") == policy_name), None)
    policy_id = policy["id"] if policy else None
    if policy is None:
        if not dry_run:
            created = client.post(
                f"/accounts/{account_id}/access/policies",
                {
                    "name": policy_name,
                    "decision": "allow",
                    "include": [{"email": {"email": email}}],
                    "precedence": 1,
                },
            )
            policy_id = created["id"]
        results.append(Result("created", f"Access policy {policy_name}"))

    body = {
        "name": fqdn,
        "domain": fqdn,
        "type": "self_hosted",
        "session_duration": SESSION_DURATION,
    }
    if policy_id:
        body["policies"] = [{"id": policy_id, "precedence": 1}]

    if not apps:
        if not dry_run:
            client.post(f"/accounts/{account_id}/access/apps", body)
        results.append(Result("created", f"Access app {fqdn}"))
        return results

    app = apps[0]
    policy_ids = {
        p["id"] if isinstance(p, dict) else p for p in (app.get("policies") or [])
    }
    already_correct = (
        app.get("session_duration") == SESSION_DURATION
        and policy_id is not None
        and policy_id in policy_ids
    )
    if already_correct:
        results.append(Result("unchanged", f"Access app {fqdn}"))
        return results
    if not dry_run:
        client.put(f"/accounts/{account_id}/access/apps/{app['id']}", body)
    results.append(Result("updated", f"Access app {fqdn}"))
    return results


def run(spec, client, dry_run=False):
    zone = spec["zone"]
    email = spec["accessEmail"]
    tunnel_id = read_tunnel_id(spec["credentialsFile"])
    zone_id, account_id = resolve_account(client, zone)

    results = []
    for sub, service in spec["services"].items():
        fqdn = f"{sub}.{zone}"
        results += reconcile_dns(client, zone_id, fqdn, tunnel_id, dry_run)
        results += reconcile_access(
            client, account_id, fqdn, email, bool(service.get("access")), dry_run
        )
    return results


def main(argv=None, client_factory=None):
    parser = argparse.ArgumentParser(
        prog="cloudflare-sync",
        description="Reconcile Cloudflare DNS and Access for tunnel-exposed services.",
    )
    parser.add_argument(
        "--spec",
        default=DEFAULT_SPEC_FILE,
        help="desired-state JSON emitted by Nix (defaults to the module-installed /etc path)",
    )
    parser.add_argument(
        "--token-file",
        default=DEFAULT_TOKEN_FILE,
        help="path to the Cloudflare API token (0600), read at runtime",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="print the diff, mutate nothing, and exit 0 clean / 1 drift / 2 error",
    )
    args = parser.parse_args(argv)

    factory = client_factory or CloudflareClient
    try:
        with open(args.spec) as handle:
            spec = json.load(handle)
        client = factory(read_token(args.token_file))
        results = run(spec, client, dry_run=args.check)
    except (CloudflareError, ValueError, KeyError) as exc:
        print(f"cloudflare-sync: {exc}", file=sys.stderr)
        return 2

    for result in results:
        verb = f"would {result.action}" if args.check else result.action
        print(f"{verb}: {result.detail}")

    if args.check and any(r.action in DRIFT_ACTIONS for r in results):
        print("cloudflare-sync: drift detected", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
