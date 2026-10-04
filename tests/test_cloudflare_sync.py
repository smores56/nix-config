import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/cloudflare/cloudflare_sync.py"
    spec = importlib.util.spec_from_file_location("cloudflare_sync", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TUNNEL_ID = "f2284d1b-5038-447b-ab50-e18dc1dba8c5"
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
            self.assertEqual([r.action for r in results], ["created", "unchanged"])
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
            self.assertEqual(results[0].action, "adopted")
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
            self.assertEqual(results[0].action, "updated")
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
            self.assertEqual(results[0].action, "updated")

    # -- Access -----------------------------------------------------------

    def test_access_created_with_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": True}})
            client = FakeClient(base_responses(**{APPS_PATH: [], POLICIES_PATH: []}))
            results = self.module.run(spec, client)
            actions = [r.action for r in results]
            self.assertEqual(actions, ["created", "created", "created"])
            writes = client.writes()
            self.assertEqual([w[1] for w in writes], [DNS_PATH, POLICIES_PATH, APPS_PATH])
            policy = writes[1][3]
            self.assertEqual(policy["decision"], "allow")
            self.assertEqual(policy["include"], [{"email": {"email": EMAIL}}])
            app = writes[2][3]
            self.assertEqual(app["domain"], f"immich.{ZONE}")
            self.assertEqual(app["session_duration"], "24h")
            self.assertEqual(app["policies"], ["created-policies"])

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
                                "policies": ["pol1"],
                            }
                        ],
                        POLICIES_PATH: [{"id": "pol1", "name": f"allow {EMAIL}"}],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["adopted", "unchanged"])
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
                                "policies": ["pol1"],
                            }
                        ],
                        POLICIES_PATH: [{"id": "pol1", "name": f"allow {EMAIL}"}],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "updated")
            update = client.writes()[-1]
            self.assertEqual(update[0], "PUT")
            self.assertEqual(update[1], f"{APPS_PATH}/app1")

    def test_access_deleted_when_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = self.make_spec(tmp, {"immich": {"port": 2283, "access": False}})
            client = FakeClient(
                base_responses(**{APPS_PATH: [{"id": "app1", "domain": f"immich.{ZONE}"}]})
            )
            results = self.module.run(spec, client)
            self.assertEqual(results[-1].action, "deleted")
            delete = client.writes()[-1]
            self.assertEqual(delete[0], "DELETE")
            self.assertEqual(delete[1], f"{APPS_PATH}/app1")

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
            self.assertEqual(results[-1].action, "unchanged")
            self.assertEqual(client.writes(), [])

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

    def test_check_exits_nonzero_on_drift_without_mutating(self):
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
                    **{
                        DNS_PATH: [{"id": "rec1", "content": PROXY_TARGET, "proxied": True}],
                        APPS_PATH: [],
                    }
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


if __name__ == "__main__":
    unittest.main()
