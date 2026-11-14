# Kanbei access: public hostname behind Access, in-VM TLS, and the locked-down shell

`kanbei.sammohr.dev` is published on the host's existing Cloudflare tunnel and gated by a
Cloudflare Access application (owner email only). There is no DNS record specific to the
name: the `*.sammohr.dev` wildcard CNAME already resolves to the tunnel, and the tunnel's
ingress rule maps the name to the guest's relay. TLS terminates inside the `kanbei` guest,
so cloudflared verifies the guest's public certificate between the connector and the
origin; a browser sees the Cloudflare edge certificate, as with every tunnel hostname.

A **private hostname route** (WARP, Gateway L4 rewrite, initial-resolved IPs) was tried
first and retired on 2026-11-13: Gateway handed both owner devices an initial-resolved IP,
but neither connection was rewritten into the tunnel, so every request reached the edge as
a public hostname. A public hostname behind Access needs no client component.

Code: `modules/nixos/kanbei-access.nix` (host), `modules/nixos/kanbei-guest-access.nix`
(guest), shared constants in `modules/lib/kanbei-access.nix`, Python in
`modules/lib/kanbei/`. The ingress rule is `webProxy.services.kanbei` in the host config.
The VM itself is `docs/kanbei-vm.md`; the threat model and accepted residuals are
`docs/kanbei-split.md`.

## Path

```
browser → Cloudflare edge (Access: owner email)
  → cloudflared (tunnel `smortress`; ingress kanbei.<domain> → https://127.0.0.1:443)
  → 127.0.0.1:443 on the host (systemd socket, group kanbei-tunnel only)
  → kanbei-chat-relay (uid kanbei-relay, TCP → AF_VSOCK 4:10000)
  → guest `kanbei-ui` (token line, then TLS; reverse proxy to nanobot's WebUI)
```

- The ingress rule uses the `https` protocol variant. cloudflared opens a fresh TLS
  connection to loopback, and because the service address is `127.0.0.1`, `web-proxy.nix`
  sets `originRequest.originServerName` to the public hostname so the guest's certificate
  verifies. `ports.kanbei` stays 443, matching the certificate and the public URL.
- Access is the only gate: the application allows the owner email and nothing else. A
  device that happens to run the Cloudflare One client can pass with its WARP identity
  (`allow_authenticate_via_warp`), but WARP is not required and no client-side setting is.
- The relay is a byte pipe. It never parses HTTP or TLS and holds no key material. Its
  systemd socket is `127.0.0.1:443`, mode `0660`, group `kanbei-tunnel`; cloudflared runs as
  a DynamicUser and joins that group as a supplementary group. The iptables chain
  `kanbei-relay-in` opens exactly that loopback port and contains no forwarding rule. The
  guest has no NIC, so the cluster and ingest VMs have no route to the relay.
- **Every channel is authenticated.** The relay writes
  `KANBEI-AUTH 1 <token>\n` as the first bytes of the vsock stream, from the root-only
  credential `/var/lib/kanbei-vm/secrets/relay-token` (`LoadCredential`). The guest's TLS
  server consumes that line from the raw socket and compares it in constant time before it
  accepts the TLS handshake; a connection without it (or with a wrong token) is closed and
  never produces an HTTP response. `/api/*` requires that authenticated connection, and
  `/api/chat` additionally requires a session token minted only by a completed WebAuthn
  assertion — there is no lane-less stub bypass. The token file is generated once by
  `kanbei-vm-prep` and shared with the guest through the read-only `kanbei-secrets` share;
  deleting it and restarting the relay/ACME/UI units rotates it.
- The guest's vsock listeners are kernel endpoints, not filesystem paths. QEMU's
  `/dev/vhost-vsock` stays root/kvm-only (a udev rule sets `0660 root:kvm`; upstream leaves
  it `0666` and `kanbei-vm-verify` asserts the rule's result); the relay unit runs with
  `PrivateDevices=true` and never sees it. The host state directories
  (`/var/lib/kanbei-vm`, `/var/lib/kanbei-acme`) are 0700 root (or the dedicated ACME
  user).

## OpenTofu fragment

The application lives in `smores56/homelabs-platform`'s `tofu/kanbei.tf` (the repo split
moved `tofu/` there); it is applied from that repo, not from this checkout. It creates one
object, the Access application, and deliberately **no** `cloudflare_dns_record` and **no**
hostname route: the wildcard CNAME resolves the name, and the tunnel ingress is declared
here.

```hcl
resource "cloudflare_zero_trust_access_application" "kanbei" {
  account_id                  = var.account_id
  name                        = "kanbei"
  type                        = "self_hosted"
  session_duration            = "720h"
  allow_authenticate_via_warp = true
  skip_interstitial           = true
  app_launcher_visible        = false

  destinations = [{
    type = "public"
    uri  = "kanbei.${var.domain}"
  }]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}
```

`var.account_id`, `var.domain` (`sammohr.dev`) and the email policy already exist in
`tofu/`. The account-wide `service_auth` policy is deliberately not attached: it accepts
any valid service token in the account, including the agent's. An unattended client that
must reach Kanbei needs its own Access decision and a reviewed terraform change.

## Access requirements and failure modes

Nothing is required on the client. The owner signs in with the email on the policy; any
other identity is denied at the edge.

- `curl -sS -o /dev/null -D - https://kanbei.sammohr.dev/` → `302` to
  `<team>.cloudflareaccess.com`. A `404` instead means the tunnel ingress rule is missing
  (cloudflared fell through to its `http_status:404` catch-all).
- A `404` **after** login, while the managed connector's log shows no request at all, is a
  second connector on the same tunnel: the edge pins a client connection to one connector,
  so a hand-started `cloudflared` with a stale config answers every request it receives
  with its own catch-all. `pgrep -a -f cloudflared` must show only the unit's
  `--no-autoupdate` process; kill anything else and the name comes back without touching
  the managed side.
- After login, the browser certificate is `CN=sammohr.dev` (the edge), not the guest's.
  That is expected for a public hostname; the guest certificate is only used between
  cloudflared and the origin. If the connector cannot verify it, the tunnel log shows a
  TLS error for `127.0.0.1:443` and the browser gets `502`.
- `dig +short kanbei.sammohr.dev` returns Cloudflare edge addresses. An address from the
  Gateway initial-resolved range (`172.64.128.0/20`, `2606:4700:0cf1:4000::/64`) means a
  private hostname route still exists somewhere in the account; it must be deleted.

## TLS in the guest

The guest's `kanbei-ui` unit is the TLS server: it listens on AF_VSOCK 10000 with the guest
certificate and key. The key is root-only at rest under `/var/lib/kanbei/tls` (0700 root,
key and certificate 0400 root) and is handed to the unprivileged `kanbei` user through
systemd credentials. Nothing on the host can read it, and the relay only splices bytes.

### Certificate request (`kanbei-cert` channel)

Schema, both directions: a 4-byte big-endian length followed by one UTF-8 JSON object on
AF_VSOCK. Guest → host CID 2, port 10001. The guest's first line is the shared relay
token; the responder also requires the peer CID to be 4.

```
KANBEI-AUTH 1 <token>\n
```

```json
{"v": 1, "cn": "kanbei.sammohr.dev", "csr": "-----BEGIN CERTIFICATE REQUEST-----\n..."}
```

Host → guest success:

```json
{"v": 1, "cn": "kanbei.sammohr.dev", "chain": "-----BEGIN CERTIFICATE-----\n...", "not_after": "2027-02-09T15:13:51Z"}
```

Host → guest failure: `{"v": 1, "error": "<short reason>"}`.

The host validates before it talks to the CA (`modules/lib/kanbei/vsock.py`):

- exactly the three request keys, `v` is the integer `1`, `cn` is exactly
  `kanbei.sammohr.dev`, `csr` is a single PEM block under 16 KiB;
- the CSR subject holds **only** the CN attribute, with that exact value (an `O`, `OU`, or
  a second CN is rejected);
- `subjectAltName`, if present, is exactly one `dNSName` for that name; any other SAN entry
  (IP, URI, email, another DNS name) is rejected, as is a duplicate or unknown extension;
- the public key is RSA ≥ 2048 bits or EC P-256 (`prime256v1`); Ed25519, RSA-1024 and other
  curves are rejected;
- the CSR's self-signature is verified with `openssl req -verify`;
- after issuance the leaf must have the fixed CN/SAN **and** the CSR's exact
  SubjectPublicKeyInfo, so a CA response for another key is refused.

The host runs `lego --csr` with the `cloudflare` DNS-01 provider. The Cloudflare token is
passed as a systemd credential (`LoadCredential=dns-api-token:…cloudflare-api-token…`) and
exported as `CLOUDFLARE_DNS_API_TOKEN` only to the Lego process. Only the account and
Lego's work directories live in `/var/lib/kanbei-acme`; no private key is created or stored
on the host. One issuance runs at a time, and issuance is rate-limited to **one certificate
per 6 hours** through the persistent marker `/var/lib/kanbei-acme/last-issue` (0600): a
request inside the window gets `{"v":1,"error":"issuance rate limited…"}` before Lego is
invoked. A guest that cannot present the token or comes from another CID gets no response
body at all. The daily renewal timer is far slower than the window, so normal renewals are
unaffected; the marker survives a responder restart (the rate limit is not per-process).

### Issuance and renewal

- On guest boot, `kanbei-cert.service` checks `/var/lib/kanbei/tls/cert.pem`. If it is
  valid for more than 30 days and carries the fixed name, it exits without a request.
  Otherwise it generates a P-256 key and CSR in tmpfs, asks the host, validates the
  returned chain, writes key/cert 0400 root, and `systemctl try-restart kanbei-ui.service`.
- `kanbei-cert.timer` retries daily (03:20 ± 15 min) and 5 minutes after boot; the
  `TryRestart` is the reload-on-renew path.
- `kanbei-ui.service` starts only after `kanbei-cert` and reads the certificate through
  credentials. A guest whose certificate cannot be issued has no TLS listener; the relay
  connection then closes rather than serving plaintext.

## The served UI

`kanbei-ui` is a TLS terminator and reverse proxy. It listens on AF_VSOCK 10000 with the
guest certificate, consumes the relay token from the raw stream before TLS, and forwards
every request — including the WebSocket upgrade the chat lane needs — to nanobot's WebUI on
`127.0.0.1:8080` (`modules/lib/kanbei/ui/server.py`). The proxy rewrites nothing except the
hop headers; it forwards the client's `Host`, adds `X-Forwarded-Proto: https` (nanobot
derives the public `wss://` URL from it), and adds three response headers that cannot
constrain the app: `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and a
CSP fragment with only `frame-ancestors 'none'; base-uri 'none'`.

- The old static shell and its JSON/passkey API are `modules/lib/kanbei/ui/legacy_shell.py`
  plus the bundle beside it: kept in the repository, referenced by nothing. Its
  "set up a passkey" prompt, its 31-line page and its unauthenticated chat lane are gone
  with it.
- Authentication is Access in front and the relay-token handshake at the connection level.
  The WebUI runs with `websocket_requires_token = false` because the guest is NIC-less and
  every connection already crossed Access and the relay; the open question is recorded on
  `smores56/sdlc#642` in case a second login turns out to be wanted.
- Model text now renders in nanobot's WebUI, which is third-party prebuilt JavaScript
  inside the trust boundary (an accepted risk in the feature design). The old shell's
  "no anchors, no images, no remote resource" property does not carry over; what still
  holds is that nothing leaves the VM except the model's own text and whatever the owner
  types.

## Spikes and how to run them

The code bar covers the offline half; the live half needs the ingress rule and the Access
application.

1. **The edge serves the name; the guest serves the origin.** From any device:

   ```sh
   curl -sS -o /dev/null -D - https://kanbei.sammohr.dev/ | head -3
   # HTTP/2 302 to <team>.cloudflareaccess.com
   ```

   After signing in, the browser certificate is `CN=sammohr.dev` (the edge). The guest
   certificate is only presented to cloudflared on `127.0.0.1:443`; the tunnel log names
   that stream, and a verification failure there surfaces as `502`.
2. **Access is the only gate.** Without a session the request is denied at the edge and
   never reaches the relay; with a session it loads and the tunnel log shows the stream.
   Check *Logs → Access* for the allow.
3. **Planted output causes no network request.** Offline, against the real shell:

   ```sh
   nix build --no-link --print-out-paths nixpkgs#chromium   # once
   python3 tests/kanbei_browser.py --chromium /nix/store/…/bin/chromium
   ```

   The test plants `![](https://example.com/x.png)` and `[click](https://example.com)` in
   the model reply, drives the form, and fails on any non-loopback request or any
   `<a>`/`<img>` in the transcript. It prints `PASS` or `SKIP` (no Chromium) and never
   claims a pass it did not observe.

## Tests

- `tests/test_kanbei_vsock.py`: framing, schema, CSR policy (fixtures under
  `tests/fixtures/kanbei/`), certificate/SPKI checks, chain split.
- `tests/test_kanbei_ui.py`: exact CSP on every response, self-contained shell, JSON-only
  API, passkey challenge lifecycle, source-level renderer invariants, and the Node-driven
  renderer test (skips honestly without Node).
- `tests/test_kanbei_relay.py`: bidirectional splice, half-close, failed vsock connect,
  and the token line as the first bytes on the guest stream.
- `tests/test_kanbei_auth.py`: the token file contract, the constant-time handshake, the
  peer-CID gate, the ACME 6-hour marker, the age-key and search-relay gates, the UI
  connection gate and the passkey-session requirement for chat.
- `tests/test_kanbei_freeze.py`: the restic freeze refcount (one stop, last cleanup starts).
- `tests/kanbei_browser.py`: the headless-Chromium spike above.

Run the Python suites with `just test` (the `unit-tests` check) and the browser script
separately; it needs a Chromium binary, which the unit-test sandbox does not carry.

## Accepted residual risks

- **The wildcard resolves the name.** `*.sammohr.dev` is a proxied CNAME and the ingress
  rule publishes `kanbei.sammohr.dev`, so it has a public answer. The Access application is
  the only gate: owner email, no bypass, no account-wide service-auth. A future change that
  removes Access from the ingress service would publish the UI; the host module asserts
  `webProxy.services.kanbei` is an `https` service with `access.enable`.
- **ACME token scope.** The responder reuses the existing `cloudflare-api-token` sops key;
  DNS-01 needs `Zone:DNS:Edit` on `sammohr.dev`. If that token is narrowed later, mint a
  scoped token and point `LoadCredential` at it.
- **Passkey verification is a stub.** Challenge lifecycle and origin/RP binding are real;
  attestation and assertion signatures are not verified yet. The remaining work, in order:
  1. persist enrolled credentials — `/api/passkey/register/verify` must store the
     credential id, the COSE public key, the signature counter and the transports, and
     `/api/passkey/auth/options` must return their ids in `allowCredentials` (today it
     returns `[]`, which is why conditional mediation can only offer a discoverable
     passkey);
  2. parse `clientDataJSON` in both verify handlers and reject a wrong `type`,
     `challenge` (already checked), `origin` other than `https://kanbei.sammohr.dev`, or
     `crossOrigin`;
  3. parse `authenticatorData`: check `rpIdHash == SHA-256("kanbei.sammohr.dev")`, the
     `UP`/`UV` flags (`userVerification: "required"`), and a non-decreasing signature
     counter against the stored credential;
  4. verify the assertion signature (ES256 with the stored P-256 key, EdDSA if enrolled)
     over `authenticatorData || SHA-256(clientDataJSON)`; mint the session only after
     that succeeds;
  5. on registration, CBOR-decode `attestationObject`, extract the credential public
     key from `authData`, and accept only `fmt: "none"` until an attestation policy
     exists;
  6. add tests with offline authenticator vectors for a good assertion plus wrong
     origin, wrong RP id, replayed counter and bad signature, so the stub cannot regress
     into a bypass. Until then the only defence in front of `/api/chat` is the
     relay-token handshake (above) plus the session gate.
- **Relay is unauthenticated at the socket.** Only group `kanbei-tunnel` (cloudflared) can
  connect, and only over loopback; a host process running as cloudflared's dynamic uid could
  use it. Host root and the DynamicUser boundary are outside this control.
- **One issuance at a time.** The responder serialises requests; a guest that asks in a
  loop can still consume ACME rate limits. The guest's 30-day freshness check and the
  daily timer are the intended rate cap, not a hostile-guest control.
