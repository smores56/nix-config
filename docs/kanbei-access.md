# Kanbei access: private route, in-VM TLS, and the locked-down shell

`kanbei.sammohr.dev` is reachable only from owner devices running the Cloudflare One
(WARP) client. It is a **private hostname route** on the host's existing tunnel: there is
no public hostname, no DNS record created for it, and no ingress rule that could serve an
unauthenticated request. TLS terminates inside the `kanbei` guest, so the browser sees the
guest's certificate end to end and Cloudflare Gateway does not decrypt the stream.

Code: `modules/nixos/kanbei-access.nix` (host), `modules/nixos/kanbei-guest-access.nix`
(guest), shared constants in `modules/lib/kanbei-access.nix`, Python in
`modules/lib/kanbei/`. The VM itself is `docs/kanbei-vm.md`; the threat model and accepted
residuals are `docs/kanbei-split.md`.

## Path

```
browser (WARP) → Cloudflare Gateway (DNS + L4 hostname route, Access)
  → cloudflared (tunnel `smortress`)
  → 127.0.0.1:443 on the host (systemd socket, group kanbei-tunnel only)
  → kanbei-chat-relay (uid kanbei-relay, TCP → AF_VSOCK 4:10000)
  → guest `kanbei-ui` (token line, then TLS; static shell + JSON API)
```

- The route is Layer 4. Gateway resolves the hostname through the tunnel, returns an
  initial resolved IP, and forwards the client's TCP stream with the original port; a
  browser's `https://kanbei.sammohr.dev` therefore arrives at loopback port 443. That is
  why `ports.kanbei` is 443 rather than a high port: nothing re-maps the destination.
- The host resolves `kanbei.sammohr.dev` to `127.0.0.1` (`networking.hosts`) so
  cloudflared's private-hostname resolver reaches the relay. No public A/AAAA record is
  added. The existing `*.sammohr.dev` CNAME does resolve publicly, but cloudflared has no
  ingress rule for this name, so a request that bypasses WARP gets the tunnel's
  `http_status:404` catch-all, and the Access application denies it first.
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

This is the exact fragment for `smores56/homelabs-platform`'s `tofu/` (the repo split moves
`tofu/` there). It is **not** applied from this checkout; copy it into the platform repo and
run that repo's `tofu apply`. It creates exactly two objects: the private hostname route and
the Access application. Deliberately **no** `cloudflare_dns_record`: adding one would make
the name a public hostname.

```hcl
# Private hostname route: kanbei.sammohr.dev is reachable only through this tunnel from
# WARP clients. TLS terminates in the guest, so Gateway must not inspect this name.
resource "cloudflare_zero_trust_network_hostname_route" "kanbei" {
  account_id = var.account_id
  hostname   = "kanbei.${var.domain}"
  tunnel_id  = var.tunnel_id
  comment    = "Kanbei chat: private hostname route (WARP only); TLS terminates in the guest"
}

# Access still gates the route. `allow_authenticate_via_warp` lets an enrolled device pass
# with its WARP identity instead of a browser redirect; the service-token policy admits an
# unattended client that presents a token, and the owner's email remains the human fallback.
resource "cloudflare_zero_trust_access_application" "kanbei" {
  account_id                  = var.account_id
  name                        = "kanbei"
  # A *private* destination, not `domain =`: a plain domain makes the app public, and Access
  # then answers the request at the edge with a browser-login redirect. The private form is
  # what a "self-hosted and private" app gets from the dashboard (hostname + port).
  destinations = [
    {
      type        = "private"
      hostname    = "kanbei.${var.domain}"
      port_range  = "443"
      l4_protocol = "tcp"
    },
  ]
  type                        = "self_hosted"
  session_duration            = "720h"
  allow_authenticate_via_warp = true
  skip_interstitial           = true
  app_launcher_visible        = false

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
    {
      id         = cloudflare_zero_trust_access_policy.service_auth.id
      precedence = 2
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}
```

`var.account_id`, `var.domain` (`sammohr.dev`), `var.tunnel_id` and the two policy resources
already exist in `tofu/main.tf`; the fragment adds no provider or variable. It does not
create a service token: mint one in the dashboard for an unattended client
(`docs/manual-steps.md`, `service/smortress/agent` has the existing shape) or rely on the
WARP identity alone.

## WARP client requirements

Owner devices: the phone and the laptop. Both must run the Cloudflare One client:

| Platform | Minimum version | Notes |
|---|---|---|
| Windows / macOS / Linux | 2025.4.929.0 | Traffic and DNS mode |
| iOS | 1.11 | Traffic and DNS mode |
| Android | 2.4.2 | Traffic and DNS mode |

Configure in the Zero Trust dashboard (none of this is in `tofu/` today, so it is a manual
step):

1. **Gateway proxy on.** Zero Trust → Traffic controls (older dashboards: Traffic
   policies) → Traffic settings → Proxy and inspection: enable *Allow Secure Web Gateway
   to proxy traffic* with **TCP** (and UDP for DNS). This is account-level, not a device
   profile setting. Private hostname routes are L4; without the proxy the connection
   reaches the edge and Access answers with a login redirect and `is_warp: false` in the
   session metadata. The API equivalent is
   `cloudflare_zero_trust_device_settings.gateway_proxy_enabled = true`.
2. **Split tunnels need no entry.** The client automatically includes the
   initial-resolved ranges at runtime (`172.64.128.0/20` IPv4, `2606:4700:0cf1::/48`
   IPv6, which also covers device and Cloudflare source IPs) and removes them from any
   exclusion; adding them by hand is only a diagnostic step. Add the range only if the
   account uses a custom initial-resolved range. Profile path: Zero Trust → Team &
   Resources → Devices → Device profiles → General profiles → (profile) → Configure.
3. **DNS through Gateway.** The client must send DNS queries for the private hostname to
   Gateway. Delete `dev` from *Local Domain Fallback* (it must not resolve
   `kanbei.sammohr.dev` locally), and keep DNS in Traffic-and-DNS mode.
4. **No TLS inspection.** Gateway must not decrypt this hostname: keep *TLS decryption* off
   for the destination (the default) or add `kanbei.sammohr.dev` to its do-not-inspect
   list. With decryption off, Access evaluates the request from WARP identity and the
   ClientHello/SNI; the browser's certificate stays the guest's.

WARP identity and posture are evaluated before the stream enters the tunnel. A device that
is not enrolled, or that fails the Access policy, never reaches cloudflared.

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

## The UI shell

`modules/lib/kanbei/ui/` is a human-owned static bundle: `index.html`, `app.js`,
`render.js`, `style.css`. There is no framework build step and no remote resource. The
server (`server.py`) serves only those four names plus the JSON API.

Response header on every path, including errors:

```
Content-Security-Policy: default-src 'none'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'
```

- Kanbei returns JSON only (`application/json`) for `/api/*`; unknown paths are JSON 404s.
- The renderer creates one `<p>` per line and one `createTextNode` per line. It never parses
  HTML, never creates an `<a>` or `<img>`, and never auto-links a URL. `![](https://…)` and
  `[click](https://…)` are shown literally. `render.js` exports `safeHref`, which refuses
  `javascript:`, `data:`, `file:`, `blob:`, protocol-relative and plain-HTTP URLs, and
  accepts only `https:` or a site-relative path; it is the gate for any future dynamic
  href (there is none today).
- Every `/api/*` request requires the relay-token handshake described above (the token is
  the first line of the connection, before TLS). `/api/chat` additionally requires
  `Authorization: Bearer <session>`, where the session is minted only by
  `/api/passkey/auth/verify`; without it the answer is a 401 and **no** chat turn runs, stub
  or local. On load the shell requests an assertion with
  `mediation: "conditional"`, so the browser offers only a passkey that already exists
  (autofill) and never prompts when there is none; the explicit **Passkey** button still
  runs the modal assertion and the registration ceremony.
- With a session, `/api/chat` forwards to the guest's local chat lane when one is configured
  and returns `{"reply": "…", "lane": "local"}`; without a lane it returns a deterministic
  stub (`lane: "stub"`). Upstream failures are JSON 502s.
- Passkey is a stub with real challenge handling: `/api/passkey/{register,auth}/options`
  issue a server-side, single-use, purpose-bound 5-minute challenge; the `/verify` calls
  consume it and refuse replays, cross-purpose use, and expiry. Cryptographic
  attestation/assertion verification is **not** implemented yet; `/verify` returns
  `{"ok": true, "stub": true}` after the lifecycle checks. WebAuthn RP ID/origin are
  `kanbei.sammohr.dev` / `https://kanbei.sammohr.dev`. The exact remaining work is in
  [Accepted residual risks](#accepted-residual-risks).

## Spikes and how to run them

The code bar covers the offline half; the live half needs the route and enrolled devices.

1. **The browser sees the origin certificate.** On a WARP device:

   ```sh
   openssl s_client -connect kanbei.sammohr.dev:443 -servername kanbei.sammohr.dev </dev/null \
     | openssl x509 -noout -subject -issuer -dates
   # subject=CN = kanbei.sammohr.dev, issuer=Let's Encrypt (or the ACME CA in use)
   ```

   In the browser, the padlock must show that issuer, not a Cloudflare edge certificate.
2. **Access gates without TLS decryption.** With WARP paused/unenrolled, the request must
   be denied by Access (or resolve nowhere); with WARP on and Gateway TLS inspection off,
   it succeeds and the certificate chain above is unchanged. Check *Logs → Access* for the
   allow, and that *Gateway → TLS inspection* shows this hostname as not inspected.
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

- **The wildcard still resolves.** `*.sammohr.dev` is a proxied CNAME, so
  `kanbei.sammohr.dev` has a public answer. There is no ingress rule for the name (the
  tunnel returns its 404 fallback) and the Access application denies first; a future change
  that adds a public DNS record or an ingress rule would reopen the path, and the host
  module asserts `webProxy.services.kanbei` stays unset.
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
