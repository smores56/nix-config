# TinyFish search behind Open WebUI's `external` web-search provider. The
# provider speaks a fixed contract the API does not: it wants a bare JSON array
# of {link,title,snippet} (not an object), it authenticates with a static value
# only, and it must never see a 5xx (a failed search should cost results, not
# the chat turn). So this shim owns the API key, reads it once at start, and
# maps each response. Loopback-only: its one client is Open WebUI on this host.
#
# The key is the sops secret `tinyfish-api-key` (owner smores, 0400), which is
# also why the unit runs as that user rather than a DynamicUser.
{ pkgs, ... }:
let
  hardening = import ../lib/hardening.nix;
  keyPath = "/run/secrets/tinyfish-api-key";

  shim = pkgs.writeText "tinyfish-shim.py" ''
    import json
    import urllib.parse
    import urllib.request
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    HOST = "127.0.0.1"
    PORT = 8899
    UPSTREAM = "https://api.search.tinyfish.ai"
    KEY_PATH = "${keyPath}"
    # The provider can only send one static value here.
    BEARER = "loopback"
    TIMEOUT = 15

    with open(KEY_PATH, encoding="utf-8") as handle:
        API_KEY = handle.read().strip()


    def search(query, count):
        """Map up to `count` TinyFish hits into the provider's shape.

        Every upstream failure becomes "no results": the provider renders a
        search error in the chat, and one flaky call must not do that.
        """
        if count <= 0:
            return []
        params = urllib.parse.urlencode(
            {"query": query, "location": "US", "language": "en"}
        )
        request = urllib.request.Request(
            UPSTREAM + "?" + params,
            headers={"X-API-Key": API_KEY, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                payload = json.load(response)
        except Exception:
            # Deliberately caught wide: the message would carry the query.
            return []
        if not isinstance(payload, dict):
            return []
        results = payload.get("results")
        if not isinstance(results, list):
            return []
        hits = []
        for result in results[:count]:
            if not isinstance(result, dict):
                continue
            hits.append(
                {
                    "link": result.get("url") or "",
                    "title": result.get("title") or "",
                    "snippet": result.get("snippet") or "",
                }
            )
        return hits


    class Handler(BaseHTTPRequestHandler):
        server_version = "tinyfish-shim"

        def do_POST(self):
            if urllib.parse.urlparse(self.path).path != "/search":
                self.reply(404, {"error": "not found"})
                return
            if self.headers.get("Authorization") != "Bearer " + BEARER:
                self.reply(401, {"error": "unauthorized"})
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                query = body["query"]
                count = int(body.get("count", 10))
                if not isinstance(query, str) or not query:
                    raise ValueError("query")
            except (ValueError, KeyError, TypeError):
                self.reply(400, {"error": "bad request"})
                return
            self.reply(200, search(query, count))

        def reply(self, status, payload):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        # No access log: the request line is client-chosen text and the query
        # itself must stay out of the journal.
        def log_message(self, fmt, *args):
            return

        def log_request(self, *args):
            return


    if __name__ == "__main__":
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
  '';
in
{
  systemd.services.tinyfish-shim = {
    description = "TinyFish search shim for Open WebUI's external web search";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "sops-nix.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = hardening // {
      ExecStart = "${pkgs.python3.interpreter} ${shim}";
      User = "smores";
      Restart = "on-failure";
      RestartSec = 5;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
