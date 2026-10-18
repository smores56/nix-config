import importlib.util
import json
import tempfile
import unittest
import unittest.mock
import urllib.error
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/cloudflare/cloudflare_sync.py"
    spec = importlib.util.spec_from_file_location("cloudflare_sync", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TUNNEL_ID = "11111111-2222-3333-4444-555555555555"
ZONE = "sammohr.dev"
ZONE_ID = "zone-123"
ACCOUNT_ID = "acct-456"
EMAIL = "sam@sammohr.dev"
PROXY_TARGET = TUNNEL_ID + ".cfargotunnel.com"

DNS_PATH = f"/zones/{ZONE_ID}/dns_records"
APPS_PATH = f"/accounts/{ACCOUNT_ID}/access/apps"
POLICIES_PATH = f"/accounts/{ACCOUNT_ID}/access/policies"


class FakeClient:
    """Scripted stand-in for CloudflareClient: canned GETs, recorded writes.

    Responses are keyed by path; write responses fall back to a synthetic id so
    callers that read the created policy id work without per-test setup.
    """

    def __init__(self, responses=None):
        self.responses = responses or {}
        self.calls = []

    def _handle(self, method, path, params=None, body=None):
        self.calls.append((method, path, params, body))
        if method == "GET":
            return self.responses.get(path, [])
        if (method, path) in self.responses:
            return self.responses[(method, path)]
        return {"id": f"created-{path.rsplit('/', 1)[-1]}"}

    def get(self, path, params=None):
        return self._handle("GET", path, params=params)

    def paginate(self, path, params=None):
        return self._handle("GET", path, params=params)

    def post(self, path, body):
        return self._handle("POST", path, body=body)

    def put(self, path, body):
        return self._handle("PUT", path, body=body)

    def delete(self, path):
        return self._handle("DELETE", path)

    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


def base_responses(**extra):
    responses = {"/zones": [{"id": ZONE_ID, "account": {"id": ACCOUNT_ID}}]}
    responses.update(extra)
    return responses


class CloudflareSyncTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def make_spec(self, tmp, services, tunnel_id=TUNNEL_ID):
        credentials = Path(tmp) / "credentials.json"
        credentials.write_text(json.dumps({"TunnelID": tunnel_id, "TunnelName": "smortress"}))
        return {
            "zone": ZONE,
            "credentialsFile": str(credentials),
            "accessEmail": EMAIL,
            "services": services,
        }

    # -- Tunnel identity --------------------------------------------------

    def test_read_tunnel_id_from_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            credentials = Path(tmp) / "credentials.json"
            credentials.write_text(json.dumps({"TunnelID": TUNNEL_ID}))
            self.assertEqual(self.module.read_tunnel_id(str(credentials)), TUNNEL_ID)

    def test_read_tunnel_id_missing_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            credentials = Path(tmp) / "credentials.json"
            credentials.write_text(json.dumps({"TunnelName": "smortress"}))
            with self.assertRaises(self.module.CloudflareError):
                self.module.read_tunnel_id(str(credentials))

    # -- DNS --------------------------------------------------------------

    def test_dns_created_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(base_responses())
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["unchanged", "created"])
            create = client.writes()[0]
            self.assertEqual(create[0], "POST")
            self.assertEqual(create[1], DNS_PATH)
            self.assertEqual(create[3]["content"], PROXY_TARGET)
            self.assertEqual(create[3]["proxied"], True)
            self.assertEqual(create[3]["name"], f"calibre.{ZONE}")

    def test_dns_adopted_when_already_correct(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [
                            {"id": "rec1", "content": PROXY_TARGET, "proxied": True},
                        ]
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "adopted")
            self.assertEqual(client.writes(), [])

    def test_dns_updated_when_content_differs(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [
                            {"id": "rec1", "content": "old.example.com", "proxied": True},
                        ]
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "updated")
            update = client.writes()[0]
            self.assertEqual(update[0], "PUT")
            self.assertEqual(update[1], f"{DNS_PATH}/rec1")

    def test_dns_updated_when_unproxied(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [
                            {"id": "rec1", "content": PROXY_TARGET, "proxied": False},
                        ]
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "updated")

    # -- Access -----------------------------------------------------------

    def test_access_created_with_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(base_responses(**{APPS_PATH: [], POLICIES_PATH: []}))
            results = self.module.run(spec, client)
            actions = [r.action for r in results]
            self.assertEqual(actions, ["created", "created", "created"])
            writes = client.writes()
            # Access before DNS: the tunnel ingress is live from Nix, so the
            # CNAME must not appear before the app that guards it.
            self.assertEqual([w[1] for w in writes], [POLICIES_PATH, APPS_PATH, DNS_PATH])
            policy = writes[0][3]
            self.assertEqual(policy["decision"], "allow")
            self.assertEqual(policy["include"], [{"email": {"email": EMAIL}}])
            self.assertEqual(policy["precedence"], 1)
            app = writes[1][3]
            self.assertEqual(app["domain"], f"immich.{ZONE}")
            self.assertEqual(app["session_duration"], "24h")
            self.assertEqual(app["policies"], [{"id": "created-policies", "precedence": 1}])

    def test_access_unchanged_when_already_correct(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": [{"id": "pol1", "precedence": 1}],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            }
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["unchanged", "adopted"])
            self.assertEqual(client.writes(), [])

    def test_access_unchanged_when_policies_are_bare_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": ["pol1"],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            }
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["unchanged", "adopted"])
            self.assertEqual(client.writes(), [])

    def test_access_updated_when_session_or_policy_differs(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "1h",
                                "policies": [{"id": "pol1", "precedence": 1}],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            }
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[0].action, "updated")
            update = next(c for c in client.writes() if c[1].startswith(APPS_PATH))
            self.assertEqual(update[0], "PUT")
            self.assertEqual(update[1], f"{APPS_PATH}/app1")

    def test_access_deleted_when_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": False}})
            client = FakeClient(
                base_responses(**{APPS_PATH: [{"id": "app1", "domain": f"immich.{ZONE}"}]})
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[0].action, "deleted")
            delete = next(c for c in client.writes() if c[0] == "DELETE")
            self.assertEqual(delete[0], "DELETE")
            self.assertEqual(delete[1], f"{APPS_PATH}/app1")

    def test_access_disabled_deletes_every_matching_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": False}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [
                            {"id": "app1", "domain": f"immich.{ZONE}"},
                            {"id": "app2", "domain": f"immich.{ZONE}"},
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["deleted", "deleted", "adopted"])
            deletes = [call[1] for call in client.writes() if call[0] == "DELETE"]
            self.assertEqual(deletes, [f"{APPS_PATH}/app1", f"{APPS_PATH}/app2"])

    def test_access_never_deletes_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": False}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[0].action, "unchanged")
            self.assertEqual(client.writes(), [])

    # -- Access service tokens (unattended clients) -----------------------

    def test_service_auth_creates_non_identity_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"immich": {"port": 2283, "access": True, "serviceAuth": True}}
            )
            client = FakeClient(base_responses(**{APPS_PATH: [], POLICIES_PATH: []}))
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["created"] * 4)
            writes = client.writes()
            self.assertEqual(
                [w[1] for w in writes],
                [POLICIES_PATH, POLICIES_PATH, APPS_PATH, DNS_PATH],
            )
            service_policy = writes[1][3]
            self.assertEqual(
                service_policy["name"], "service auth (any valid service token)"
            )
            # The dashboard "Service Auth" action is `non_identity` at the API,
            # accepting any token minted in the account rather than naming one.
            self.assertEqual(service_policy["decision"], "non_identity")
            self.assertEqual(
                service_policy["include"], [{"any_valid_service_token": {}}]
            )
            self.assertEqual(service_policy["precedence"], 2)
            app = writes[2][3]
            self.assertEqual([p["precedence"] for p in app["policies"]], [1, 2])

    def test_service_auth_absent_creates_only_the_email_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(base_responses(**{APPS_PATH: [], POLICIES_PATH: []}))
            self.module.run(spec, client)
            names = [w[3]["name"] for w in client.writes() if w[1] == POLICIES_PATH]
            self.assertEqual(names, [f"allow {EMAIL}"])

    def test_service_auth_unchanged_when_policies_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"immich": {"port": 2283, "access": True, "serviceAuth": True}}
            )
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": ["pol1", "pol2"],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            },
                            {
                                "id": "pol2",
                                "name": self.module.SERVICE_AUTH_POLICY_NAME,
                                "decision": self.module.SERVICE_AUTH_DECISION,
                                "include": [{"any_valid_service_token": {}}],
                            },
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["unchanged", "adopted"])
            self.assertEqual(client.writes(), [])

    def test_service_auth_updates_app_missing_service_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"immich": {"port": 2283, "access": True, "serviceAuth": True}}
            )
            client = FakeClient(
                base_responses(
                    **{
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": [{"id": "pol1", "precedence": 1}],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            },
                            {
                                "id": "pol2",
                                "name": self.module.SERVICE_AUTH_POLICY_NAME,
                                "decision": self.module.SERVICE_AUTH_DECISION,
                                "include": [{"any_valid_service_token": {}}],
                            },
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[0].action, "updated")
            update = next(c for c in client.writes() if c[1].startswith(APPS_PATH))
            self.assertEqual(update[1], f"{APPS_PATH}/app1")
            self.assertEqual([p["precedence"] for p in update[3]["policies"]], [1, 2])

    # -- Protected hostnames (a typo must never publish them) -------------

    def test_protected_hostname_refuses_deletion(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"ssh": {"port": 22, "protocol": "ssh", "access": False}}
            )
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [{"id": "app1", "domain": f"ssh.{ZONE}"}],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "protected")
            self.assertIn("ssh", results[-1].detail)
            self.assertEqual([c for c in client.writes() if c[0] == "DELETE"], [])

    def test_protected_hostname_refusal_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"ssh": {"port": 22, "protocol": "ssh", "access": False}}
            )
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [{"id": "app1", "domain": f"ssh.{ZONE}"}],
                    }
                )
            )
            self.assertEqual(self.run_main(spec, client, check=False), 2)
            self.assertEqual([c for c in client.writes() if c[0] == "DELETE"], [])

    def test_protected_hostname_refusal_mutates_nothing_in_check_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"llm": {"port": 8081, "protocol": "tcp", "access": False}}
            )
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [{"id": "app1", "domain": f"llm.{ZONE}"}],
                    }
                )
            )
            self.assertEqual(self.run_main(spec, client, check=True), 2)
            self.assertEqual(client.writes(), [])

    # (Access-before-DNS ordering is asserted exactly in
    # test_access_created_with_policy's write-order check.)

    def test_every_protected_subdomain_refuses_deletion(self):
        # Behavioural, not a restatement of the constant: clearing
        # access.enable on any protected hostname must be refused, and refused
        # *before* any DNS record is written.
        for sub in ("ssh", "llm", "searx", "ntfy"):
            with self.subTest(sub=sub), tempfile.TemporaryDirectory() as tmp:
                spec = self.make_spec(tmp, {sub: {"port": 1234, "access": False}})
                client = FakeClient(
                    base_responses(
                        **{
                            DNS_PATH: [
                                {"id": "rec1", "content": PROXY_TARGET, "proxied": True}
                            ],
                            APPS_PATH: [{"id": "app1", "domain": f"{sub}.{ZONE}"}],
                        }
                    )
                )
                results = self.module.run(spec, client)
                self.assertEqual([r.action for r in results], ["protected"])
                self.assertEqual(client.writes(), [])

    def test_protected_hostname_refused_even_without_a_live_app(self):
        # A stale or hand-edited spec that clears `access.enable` must still be
        # refused: the DNS record and tunnel ingress already publish the service.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(
                tmp, {"ssh": {"port": 22, "protocol": "ssh", "access": False}}
            )
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "protected")
            self.assertEqual(client.writes(), [])

    def test_protected_port_refuses_deletion(self):
        # Protection follows the service, not just the label: a rename that keeps
        # a critical port must still be refused.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"gateway": {"port": 22, "access": False}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [{"id": "app1", "domain": f"gateway.{ZONE}"}],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["protected"])
            self.assertEqual(client.writes(), [])

    def test_duplicate_access_apps_are_deleted(self):
        # A second app on the same hostname is one we do not own: delete it so the
        # endpoint is guarded by exactly the declared app.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": ["pol1"],
                            },
                            {"id": "app2", "domain": f"immich.{ZONE}"},
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            }
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertIn("deleted", [r.action for r in results])
            deletes = [call[1] for call in client.writes() if call[0] == "DELETE"]
            self.assertEqual(deletes, [f"{APPS_PATH}/app2"])

    def test_access_updated_when_an_extra_policy_is_attached(self):
        # Extra live policies are drift to revert, not `unchanged`: an app must
        # carry exactly the policies the config declares.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": ["pol1", "pol-extra"],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            },
                            {
                                "id": "pol2",
                                "name": self.module.SERVICE_AUTH_POLICY_NAME,
                                "decision": self.module.SERVICE_AUTH_DECISION,
                                "include": [{"any_valid_service_token": {}}],
                            },
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[0].action, "updated")
            update = client.writes()[-1]
            self.assertEqual(update[3]["policies"], [{"id": "pol1", "precedence": 1}])

    def test_access_errors_when_adopted_policy_mismatches(self):
        # A same-named account policy with a permissive include must not be
        # adopted silently: the reconciler refuses (exit 2) instead.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        APPS_PATH: [],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"everyone": {}}],
                            }
                        ],
                    }
                )
            )
            with self.assertRaises(self.module.CloudflareError):
                self.module.run(spec, client)

    def test_access_updated_when_policy_precedence_differs(self):
        # Same policy id, different precedence (a dashboard reorder) is drift.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(
                base_responses(
                    **{
                        APPS_PATH: [
                            {
                                "id": "app1",
                                "domain": f"immich.{ZONE}",
                                "session_duration": "24h",
                                "policies": [{"id": "pol1", "precedence": 2}],
                            }
                        ],
                        POLICIES_PATH: [
                            {
                                "id": "pol1",
                                "name": f"allow {EMAIL}",
                                "decision": "allow",
                                "include": [{"email": {"email": EMAIL}}],
                            }
                        ],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[0].action, "updated")

    # -- --check ----------------------------------------------------------

    def run_main(self, spec, client, check):
        with tempfile.TemporaryDirectory() as tmp:
            spec_path = Path(tmp) / "spec.json"
            spec_path.write_text(json.dumps(spec))
            token_path = Path(tmp) / "api-token"
            token_path.write_text("tok\n")
            argv = ["--spec", str(spec_path), "--token-file", str(token_path)]
            if check:
                argv.append("--check")
            return self.module.main(argv, client_factory=lambda _: client)

    def test_check_exits_one_on_drift_without_mutating(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(base_responses())
            code = self.run_main(spec, client, check=True)
            self.assertEqual(code, 1)
            self.assertEqual(client.writes(), [])

    def test_check_exits_zero_when_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(
                base_responses(
                    **{DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}]}
                )
            )
            code = self.run_main(spec, client, check=True)
            self.assertEqual(code, 0)

    def test_apply_exits_zero_and_mutates(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            client = FakeClient(base_responses())
            code = self.run_main(spec, client, check=False)
            self.assertEqual(code, 0)
            self.assertEqual(client.writes()[0][0], "POST")

    def test_check_exits_two_on_api_error(self):
        class RaisingClient(FakeClient):
            def paginate(self, path, params=None):
                raise self.module.CloudflareError("boom")

        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            code = self.run_main(spec, RaisingClient(), check=True)
            self.assertEqual(code, 2)

    def test_apply_exits_two_on_api_error(self):
        class RaisingClient(FakeClient):
            def paginate(self, path, params=None):
                raise self.module.CloudflareError("boom")

        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            code = self.run_main(spec, RaisingClient(), check=False)
            self.assertEqual(code, 2)

    def test_main_exits_two_on_malformed_spec(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"calibre": {"port": 8181, "access": False}})
            del spec["zone"]
            code = self.run_main(spec, FakeClient(base_responses()), check=False)
            self.assertEqual(code, 2)

    def test_main_exits_two_when_services_is_not_an_object(self):
        # `services` as a list raises AttributeError; it must be an error (2),
        # never drift (1) or a crash that the shell reports as 1.
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, [])
            code = self.run_main(spec, FakeClient(base_responses()), check=True)
            self.assertEqual(code, 2)

    def test_main_exits_two_when_spec_file_is_missing(self):
        code = self.module.main(
            ["--spec", "/nonexistent/spec.json", "--token-file", "/nonexistent/api-token"],
            client_factory=lambda _: FakeClient(base_responses()),
        )
        self.assertEqual(code, 2)

    # -- token / credentials parsing -------------------------------------

    def test_read_token_missing_file_raises(self):
        with self.assertRaises(self.module.CloudflareError):
            self.module.read_token("/nonexistent/api-token")

    def test_read_token_empty_file_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / "api-token"
            token.write_text("  \n")
            with self.assertRaises(self.module.CloudflareError):
                self.module.read_token(str(token))

    def test_read_tunnel_id_malformed_json_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            credentials = Path(tmp) / "credentials.json"
            credentials.write_text("not json")
            with self.assertRaises(self.module.CloudflareError):
                self.module.read_tunnel_id(str(credentials))


class FakeHTTPResponse:
    """Minimal context-manager stand-in for urlopen's return value."""

    def __init__(self, payload):
        self._body = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self._body


def _payload(result, total_pages=None):
    payload = {"success": True, "result": result}
    if total_pages is not None:
        payload["result_info"] = {"total_pages": total_pages}
    return payload


class CloudflareClientTests(unittest.TestCase):
    """Exercises the real _request against a patched urlopen."""

    def setUp(self):
        self.module = load_module()
        self.client = self.module.CloudflareClient("tok-123", base="https://api.example/v4")

    def test_request_builds_url_and_auth_header(self):
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", return_value=FakeHTTPResponse(_payload([]))
        ) as urlopen:
            self.client.get("/zones", params={"name": ZONE, "per_page": 100})
        request = urlopen.call_args.args[0]
        self.assertEqual(
            request.full_url,
            "https://api.example/v4/zones?name=sammohr.dev&per_page=100",
        )
        self.assertEqual(request.get_header("Authorization"), "Bearer tok-123")
        self.assertEqual(request.get_method(), "GET")

    def test_request_unwraps_result(self):
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", return_value=FakeHTTPResponse(_payload([1]))
        ):
            self.assertEqual(self.client.get("/zones"), [1])

    def test_request_http_error_becomes_cloudflare_error(self):
        error = urllib.error.HTTPError(
            "https://api.example/v4/zones", 403, "Forbidden", {}, None
        )
        error.read = lambda: b"denied"
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", side_effect=error
        ):
            with self.assertRaises(self.module.CloudflareError) as ctx:
                self.client.get("/zones")
        message = str(ctx.exception)
        self.assertIn("HTTP 403", message)
        self.assertIn("Zone:DNS:Write", message)
        self.assertIn("Access: Apps and Policies:Write", message)

    def test_request_http_error_401_also_hints(self):
        error = urllib.error.HTTPError("https://api.example/v4/zones", 401, "Unauthorized", {}, None)
        error.read = lambda: b"nope"
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", side_effect=error
        ):
            with self.assertRaises(self.module.CloudflareError) as ctx:
                self.client.get("/zones")
        self.assertIn("HTTP 401", str(ctx.exception))
        self.assertIn("Zone:DNS:Write", str(ctx.exception))

    def test_request_other_http_error_has_no_scope_hint(self):
        error = urllib.error.HTTPError("https://api.example/v4/zones", 500, "Boom", {}, None)
        error.read = lambda: b"server"
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", side_effect=error
        ):
            with self.assertRaises(self.module.CloudflareError) as ctx:
                self.client.get("/zones")
        self.assertIn("HTTP 500", str(ctx.exception))
        self.assertNotIn("Zone:DNS:Write", str(ctx.exception))

    def test_request_timeout_becomes_cloudflare_error(self):
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", side_effect=TimeoutError("timed out")
        ):
            with self.assertRaises(self.module.CloudflareError):
                self.client.get("/zones")

    def test_request_success_false_becomes_cloudflare_error(self):
        payload = {"success": False, "errors": [{"code": 1000, "message": "bad"}]}
        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", return_value=FakeHTTPResponse(payload)
        ):
            with self.assertRaises(self.module.CloudflareError):
                self.client.get("/zones")

    def test_paginate_follows_total_pages(self):
        pages = {
            "page=1": _payload([{"id": "a"}], total_pages=2),
            "page=2": _payload([{"id": "b"}], total_pages=2),
        }

        def fake_urlopen(request, timeout=None):
            for marker, payload in pages.items():
                if request.full_url.endswith(marker):
                    return FakeHTTPResponse(payload)
            raise AssertionError(request.full_url)

        with unittest.mock.patch.object(
            self.module.urllib.request, "urlopen", side_effect=fake_urlopen
        ):
            items = self.client.paginate(
                "/zones/z/dns_records", params={"type": "CNAME", "per_page": 100}
            )
        self.assertEqual([i["id"] for i in items], ["a", "b"])

    def test_paginate_single_page_without_result_info(self):
        with unittest.mock.patch.object(
            self.module.urllib.request,
            "urlopen",
            return_value=FakeHTTPResponse(_payload([{"id": "only"}])),
        ):
            items = self.client.paginate("/zones/z/dns_records")
        self.assertEqual([i["id"] for i in items], ["only"])

    def test_run_reconciles_more_than_one_page_of_dns(self):
        spec = {
            "zone": ZONE,
            "credentialsFile": None,
            "accessEmail": EMAIL,
            "services": {"calibre": {"port": 8181, "access": False}},
        }
        with tempfile.TemporaryDirectory() as tmp:
            credentials = Path(tmp) / "credentials.json"
            credentials.write_text(json.dumps({"TunnelID": TUNNEL_ID}))
            spec["credentialsFile"] = str(credentials)
            other = [{"id": f"r{i}", "name": f"other{i}.{ZONE}"} for i in range(99)]
            match = {"id": "match", "content": PROXY_TARGET, "proxied": True}
            requested = []

            def fake_urlopen(request, timeout=None):
                url = request.full_url
                requested.append(url)
                if "dns_records" in url:
                    if "page=2" in url:
                        return FakeHTTPResponse(_payload(other, total_pages=2))
                    return FakeHTTPResponse(_payload([match, *other], total_pages=2))
                if "access/apps" in url:
                    return FakeHTTPResponse(_payload([], total_pages=1))
                if "/zones" in url:
                    return FakeHTTPResponse(
                        _payload([{"id": ZONE_ID, "account": {"id": ACCOUNT_ID}}])
                    )
                raise AssertionError(url)

            client = self.module.CloudflareClient("tok", base="https://api.example/v4")
            with unittest.mock.patch.object(
                self.module.urllib.request, "urlopen", side_effect=fake_urlopen
            ):
                results = self.module.run(spec, client)
        self.assertEqual(results[-1].action, "adopted")
        # The second page was fetched, so a match past the first 100 is not missed.
        self.assertTrue(any("dns_records" in url and "page=2" in url for url in requested))


if __name__ == "__main__":
    unittest.main()
