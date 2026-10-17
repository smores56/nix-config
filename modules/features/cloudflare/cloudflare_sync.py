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
endpoint public — except for a small set of protected services (ssh/llm/
searx/ntfy, matched by hostname or port): their apps are never deleted, because
a Nix typo that clears `access.enable` must not publish them. The reconciler refuses and reports
loudly instead.

A service may also request `serviceAuth`: an extra Access policy whose action
is the dashboard's "Service Auth" (the API's `non_identity` decision) with a
selector that accepts *any* valid account service token. The operator mints the
token in the dashboard; the reconciler never names one, so unattended clients
(`cloudflared access ssh|tcp`) authenticate without an IdP browser login while
the email allow-list policy stays as a human fallback.

The tunnel UUID is never authored: it is read out of the tunnel credentials
file's `TunnelID` at runtime and used to build `<uuid>.cfargotunnel.com`.

`--check` prints the diff, mutates nothing, and exits non-zero when drift
exists, so CI or a rebuild can detect a dashboard edit that the next apply
would revert. Exit codes: 0 clean, 1 drift, 2 an API, spec, or safety error (a
permission problem, a malformed spec, or a refused deletion of a protected
service are never mistaken for drift).

Scope of drift repair: the reconciler owns each app's *set* of policies (an
extra live policy is reverted) and adopts shared account policies by name. It
does not re-verify or revert the *contents* of an adopted shared policy — only
the account owner can edit those in the dashboard, so that is out of scope.
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
# The dashboard's "Service Auth" action is the API's `non_identity` decision
# paired with a selector that accepts any token in the account, so the operator
# mints the token in the dashboard and the reconciler never names one.
SERVICE_AUTH_DECISION = "non_identity"
SERVICE_AUTH_POLICY_NAME = "service auth (any valid service token)"
# Hostnames whose Access app is never deleted. A Nix typo that clears
# `access.enable` must not silently publish sshd/the LLM/SearXNG; ntfy is
# already protected by its own assertion (modules/nixos/notify.nix). Mirrors the
# `protected` list in modules/nixos/web-proxy.nix: that assertion stops the
# mistake at evaluation; this is the second line of defence for a stale or
# hand-edited spec.
PROTECTED_SUBDOMAINS = frozenset({"ssh", "llm", "searx", "ntfy"})
# The origin ports those services listen on: modules/ports.nix for llm/searx/
# ntfy, modules/options.nix for ntfy's knob, modules/nixos/ssh.nix for sshd.
# Protection follows the service, not just its label: a rename that keeps the
# port, or a port move that keeps the name, is still refused, so a one-sided
# edit cannot slip a critical endpoint out from under the guard.
PROTECTED_PORTS = frozenset({22, 8081, 8899, 2586})


def is_protected(sub, port):
    return sub in PROTECTED_SUBDOMAINS or port in PROTECTED_PORTS


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
            # Truncate: an error body is echoed into a systemd journal, and a
            # verbose one can be large (or carry request context we do not need).
            detail = exc.read().decode(errors="replace")[:500]
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
        except OSError as exc:
            # Timeouts and other socket errors during read() bypass URLError; they
            # are API failures (exit 2), never drift (exit 1).
            raise CloudflareError(f"{method} {path} -> {exc}") from exc
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


def _ensure_policy(
    client, account_id, policies, name, decision, include, precedence, dry_run
):
    """Return (policy_id, result). Idempotent by policy name.

    `policies` is the account's policy list, fetched once by the caller so a
    hostname carrying two policies does not paginate the API twice. A reusable
    account policy that already exists is adopted; otherwise one is created. In
    `dry_run` a missing policy yields `(None, Result("created"))`, since no id
    exists yet — the caller must then treat the app as needing an update rather
    than reporting it unchanged.
    """
    policy = next((p for p in policies if p.get("name") == name), None)
    if policy is not None:
        return policy["id"], None
    if dry_run:
        return None, Result("created", f"Access policy {name}")
    created = client.post(
        f"/accounts/{account_id}/access/policies",
        {
            "name": name,
            "decision": decision,
            "include": include,
            "precedence": precedence,
        },
    )
    return created["id"], Result("created", f"Access policy {name}")


def reconcile_access(
    client, account_id, sub, port, fqdn, email, wanted, service_auth, dry_run
):
    apps = [
        app
        for app in client.paginate(
            f"/accounts/{account_id}/access/apps", params={"per_page": 100}
        )
        if app.get("domain") == fqdn
    ]

    if not wanted:
        if is_protected(sub, port):
            # Defence in depth: a typo (or a stale hand-edited spec) that clears
            # `access.enable` must not make a critical hostname public. Never
            # delete its app — and refuse even when no app exists yet, because
            # the DNS record and tunnel ingress already publish the loopback
            # service. Report a `protected` result (main escalates it to a loud
            # error); the Nix assertion should have failed evaluation first.
            return [
                Result(
                    "protected",
                    f"refused to remove Access for {fqdn}: {sub!r} (port {port}) "
                    f"is a protected service and is never made public",
                )
            ]
        if not apps:
            return [Result("unchanged", f"Access {fqdn}: off")]
        # Delete every app on this hostname, not just the first: a second app left
        # behind would keep guarding the endpoint while we report it public.
        for app in apps:
            if not dry_run:
                client.delete(f"/accounts/{account_id}/access/apps/{app['id']}")
        return [Result("deleted", f"Access app {fqdn} ({app['id']})") for app in apps]

    results = []
    wanted_policies = []
    policies_changed = False

    # (name, decision, include, precedence) for every policy this hostname
    # needs: the email allow-list, plus a Service Auth policy when unattended
    # clients reach it. One fetch of the account's policies serves them all.
    descriptors = [(f"allow {email}", "allow", [{"email": {"email": email}}], 1)]
    if service_auth:
        descriptors.append(
            (
                SERVICE_AUTH_POLICY_NAME,
                SERVICE_AUTH_DECISION,
                [{"any_valid_service_token": {}}],
                2,
            )
        )
    policies = client.paginate(
        f"/accounts/{account_id}/access/policies", params={"per_page": 100}
    )
    for name, decision, include, precedence in descriptors:
        policy_id, created = _ensure_policy(
            client, account_id, policies, name, decision, include, precedence, dry_run
        )
        policies_changed = policies_changed or created is not None
        if created:
            results.append(created)
        if policy_id:
            wanted_policies.append((policy_id, precedence))

    body = {
        "name": fqdn,
        "domain": fqdn,
        "type": "self_hosted",
        "session_duration": SESSION_DURATION,
    }
    if wanted_policies:
        body["policies"] = [
            {"id": policy_id, "precedence": precedence}
            for policy_id, precedence in wanted_policies
        ]

    if not apps:
        if not dry_run:
            client.post(f"/accounts/{account_id}/access/apps", body)
        results.append(Result("created", f"Access app {fqdn}"))
        return results

    app = apps[0]
    live_ids = {
        p["id"] if isinstance(p, dict) else p for p in (app.get("policies") or [])
    }
    wanted_ids = {policy_id for policy_id, _ in wanted_policies}
    # Equality, not a subset: this app's policies are fully owned by the config,
    # so an extra live policy (e.g. a permissive one added in the dashboard) is
    # drift to revert, not something to report `unchanged`.
    already_correct = (
        app.get("session_duration") == SESSION_DURATION
        and not policies_changed
        and bool(wanted_ids)
        and wanted_ids == live_ids
    )
    if already_correct:
        results.append(Result("unchanged", f"Access app {fqdn}"))
    else:
        if not dry_run:
            client.put(f"/accounts/{account_id}/access/apps/{app['id']}", body)
        results.append(Result("updated", f"Access app {fqdn}"))
    # Any further app on this hostname is one we do not own: delete it so the
    # endpoint is guarded by exactly the declared app. A lingering duplicate
    # could keep an unintended policy in force while we report the host correct.
    for extra in apps[1:]:
        if not dry_run:
            client.delete(f"/accounts/{account_id}/access/apps/{extra['id']}")
        results.append(Result("deleted", f"duplicate Access app {fqdn} ({extra['id']})"))
    return results


def run(spec, client, dry_run=False):
    zone = spec["zone"]
    email = spec["accessEmail"]
    tunnel_id = read_tunnel_id(spec["credentialsFile"])
    zone_id, account_id = resolve_account(client, zone)

    results = []
    for sub, service in spec["services"].items():
        fqdn = f"{sub}.{zone}"
        # Access first. The tunnel ingress is live from Nix regardless of this
        # run, so a CNAME published before its Access app exists would serve the
        # loopback service to anyone who learns the hostname; ordering Access
        # first means a failed Access call aborts the run (exit 2) before the DNS
        # record is created.
        access_results = reconcile_access(
            client,
            account_id,
            sub,
            service.get("port"),
            fqdn,
            email,
            bool(service.get("access")),
            bool(service.get("serviceAuth")),
            dry_run,
        )
        results += access_results
        # A refused (protected) hostname must not get a DNS record either.
        if any(r.action == "protected" for r in access_results):
            continue
        results += reconcile_dns(client, zone_id, fqdn, tunnel_id, dry_run)
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
    # AttributeError/TypeError catch a malformed spec (e.g. `services` as a list,
    # or a service value that is not an object) so it is reported as an error
    # (exit 2), never mistaken for drift (exit 1).
    except (CloudflareError, OSError, ValueError, KeyError, AttributeError, TypeError) as exc:
        print(f"cloudflare-sync: {exc}", file=sys.stderr)
        return 2

    for result in results:
        verb = f"would {result.action}" if args.check else result.action
        print(f"{verb}: {result.detail}")

    if any(r.action == "protected" for r in results):
        print(
            "cloudflare-sync: REFUSED to delete Cloudflare Access for a protected "
            "service (ssh/llm/searx/ntfy, or their ports) and left it in place: "
            "dotfiles.webProxy.services declares it public, which must never happen. "
            "Fix the config — do not work around this.",
            file=sys.stderr,
        )
        return 2

    if args.check and any(r.action in DRIFT_ACTIONS for r in results):
        print("cloudflare-sync: drift detected", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
