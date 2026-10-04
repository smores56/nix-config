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
            self.assertEqual(policy["precedence"], 1)
            app = writes[2][3]
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
                        POLICIES_PATH: [{"id": "pol1", "name": f"allow {EMAIL}"}],
                    }
                )
            )
            results = self.module.run(spec, client)
            self.assertEqual([r.action for r in results], ["adopted", "unchanged"])
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
                                "policies": [{"id": "pol1", "precedence": 1}],
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
            self.assertEqual([r.action for r in results], ["adopted", "deleted", "deleted"])
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
        self.assertEqual(results[0].action, "adopted")
        # The second page was fetched, so a match past the first 100 is not missed.
        self.assertTrue(any("dns_records" in url and "page=2" in url for url in requested))


if __name__ == "__main__":
    unittest.main()
