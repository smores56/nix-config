# Kanbei search guest

The search channel is Kanbei's only way to reach the network. Kanbei has no NIC,
so a query leaves the vault through the Firecracker `search` guest, which holds
Kanbei's only TinyFish key. The guest is deliberately narrow: a strict vsock
protocol, four fail-closed gates, one egress name, and stripped text back.

Kanbei → host relay (Kanbei's vsock host side, port 7101) → search guest vsock
cid 14, port 7024 → gate ladder → `api.search.tinyfish.ai` through the tap's host
proxy.

Source files:

| piece | file |
|---|---|
| facts, tap, allowlist, ports | `modules/lib/ingest-vm.nix` |
| host and guest rendering | `modules/nixos/ingest-vm.nix` |
| gate ladder, prompt, stripping | `modules/lib/search/gates.py` |
| persisted limiter | `modules/lib/search/limits.py` |
| judge and TinyFish clients | `modules/lib/search/judge.py`, `modules/lib/search/tinyfish.py` |
| vsock service | `modules/lib/search/searchd.py` |
| host relay | `modules/lib/search/search_relay.py` |
| model manifest | `modules/lib/search-models.json` |
| planted suite | `tests/search/fixtures/cases.json`, `tests/search/run_suite.py` |

The guest is part of `ingestVm.enable`, like the five ingest sources. The host
plumbing is `search-relay.service` (owns the Kanbei-side vsock listener) and
`search-vm-model.service` (stages the read-only model image before boot).

## Gate order

Every query walks the same ladder and stops at the first failure. Nothing is
sent to TinyFish until all four gates passed.

| # | gate | refusal reason | detail |
|---|---|---|---|
| 1 | DLP scan | `dlp` | whitespace-normalised query, pattern id only |
| 2 | length cap | `length` | `ingestVm.searchMaxQueryChars` (default 100, hard ceiling 320) |
| 3 | rate + budget | `rate`, `budget`, `state` | sliding minute and UTC-day counters, persisted |
| 4 | Guardian judge | `judge` | loopback llama.cpp; any error, timeout or missing verdict blocks |

After the gates, a TinyFish error or an unusable result document is `upstream`
and returns no results. A malformed request line is `request`. Every response is
one JSON line; blocked responses never echo the query.

### 1. DLP

`gates.normalize` applies NFKC, drops format characters (zero-width spaces and
bidi overrides, so they cannot split a match), then collapses every whitespace
run to one space. The scan runs on that form:

| rule id | shape |
|---|---|
| `control-chars` | any remaining C0/C1 control character |
| `private-key` | `-----BEGIN … PRIVATE KEY-----` |
| `aws-access-key` | `AKIA`/`ASIA`/`ABIA`/`ACCA` + 16 uppercase alphanumerics |
| `github-token` | `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` + 20, or `github_pat_` + 22 |
| `slack-token` | `xoxb-`/`xoxa-`/`xoxp-`/`xoxr-`/`xoxs-` |
| `jwt` | three base64url segments starting `eyJ` |
| `credentialed-url` | `scheme://user:password@` |
| `bearer-token` | `Bearer` + 16 opaque characters |
| `email` | `local@domain.tld` |
| `ssn` | `123-45-6789` |
| `card` | 13–19 digits with single spaces or dashes |
| `keyword-secret` | `password`/`token`/`api key`/`secret`/`seed phrase`/… + `:`/`=`/`is` + a 6+ character value |
| `hex-blob` | 32+ hex characters |
| `base64-blob` | 32+ base64 characters with optional `=` padding |
| `long-digits` | 9+ consecutive digits |
| `digit-run` | 9+ digits across spaces, dots, dashes or parentheses (phone, account, routing) |
| `entropy` | a 24+ character letter+digit token at ≥ 4.2 bits/char |

The entropy floor is measured per token with the token's own alphabet:
`correcthorsebatterystaple2024` is 3.69, `Zx9Qm2Lp7Rt4Vb8Nc3Wd6Kf1` is 4.58.
A token shorter than 24 characters, or one without both a letter and a digit, is
not scored. A payload split across whitespace therefore drops below the blob
floors; catching that assembled form is the judge's job, which is why the judge
sees the whole normalised query and why its threshold is separate from DLP's.

The scanner returns a rule id, never the match. The log record for a blocked
query carries `chars`, `rule` and `digest` (`sha256(normalised query)` truncated
to 16 hex characters); the query text itself is never written. The rule id is
logged but not returned to Kanbei, so the channel is not a filter oracle.

### 2. Length cap

The cap applies to the normalised query, not the raw bytes. It is the NixOS
option `ingestVm.searchMaxQueryChars` (default 100), rendered into the guest
config. The code-level ceiling is `gates.MAX_QUERY_CHARS_HARD = 320`; the option
type refuses anything larger, and `searchd` refuses a rendered config above it.

### 3. Rate limit and daily budget

Defaults: 20 queries per sliding minute and 300 per UTC day
(`ingestVm.searchPerMinute`, `ingestVm.searchDailyBudget`). The state is
`/var/lib/search/limits.json` (mode 0600) on the guest's small writable volume
(`/var/lib/microvms/search-state/state.img`, mounted at `/var/lib/search`),
replaced atomically with an fsync. The guest root is tmpfs, which is why the
counters live on that volume: a guest restart or a crash never resets them.
Deleting the image is the deliberate budget reset, and it is only possible while
the guest is stopped. A query reserves its slot *before* the judge and the
upstream call; a judge or upstream failure still consumes it.

A missing state file is a first boot. A malformed one is a `state` block for
every query until an operator removes it: the limiter fails closed rather than
granting a fresh budget. A clock that jumps backwards discards future-dated hits
instead of locking the channel out.

### 4. Granite Guardian

The judge is `granite-guardian-3.1-2b` (Q4_K_M) served by a CPU-only
`llama-server` on `127.0.0.1:8091`, with `--threads 2 --ctx-size 2048
--n-gpu-layers 0 --no-warmup`. Weights are 1.44 GiB and mmapped from a read-only
block device; the guest has 2560 MiB. The model manifest
(`modules/lib/search-models.json`) pins repository, file, size and sha256.

`gates.guardian_prompt` renders the Granite Guardian 3.x scoring prompt with the
model's conversation and risk-definition scaffolding, a BYOC `<guardian>` block
holding the custom "smuggled data exfiltration" criterion, and an instruction to
answer `<score>yes</score>` or `<score>no</score>`. The request is sent to
`/completion` with `temperature: 0`, `top_k: 1`, `top_p: 1`, `n_predict: 16`,
`cache_prompt: false` (greedy and deterministic). Proxy environment variables are
ignored, so the judge call cannot leave the guest.

`gates.parse_verdict` accepts `<score>yes|no</score>`, ignoring a reasoning
block. Granite 3.x can emit a bare `Yes`/`No` instead of the tag; only the first
word counts, so a stray `no` later in a refusal is not a verdict. A missing
verdict, a connection error, a timeout, an HTTP error, a malformed body or a
missing model all block.

### Egress and results

The guest's only allowlisted name is `api.search.tinyfish.ai`, through the host
proxy on `10.77.14.1:3128`; the resolver answers only that name. The key is read
from `/run/ingest-secret/env`, which must contain exactly one
`TINYFISH_API_KEY=<key>` line; any other shape refuses the service at startup.

TinyFish is called as `GET https://api.search.tinyfish.ai/?query=…` with
`X-API-Key`. Results are stripped with a stdlib HTML parser (script/style bodies
dropped), entity-decoded, reduced to plain text (Markdown links keep their
label, autolinks lose their brackets, remaining angle brackets removed,
control/format characters dropped), and bounded to five results, 200-character
titles, 400-character snippets and 4 KiB of JSON. A URL survives only as inert
plain text and only when it is a clean absolute `http(s)` URL without userinfo.
No HTML, markup or auto-linkable construct reaches Kanbei.

## Wire protocol

One connection, one request line, one response line. The request cap is 8 KiB;
the response cap is 8 KiB.

```json
{"v":1,"op":"search","query":"how do I convert USD to EUR","id":"optional-64-chars"}
```

```json
{"v":1,"op":"search","decision":"allow","reason":"ok","results":[{"title":"…","url":"https://…","snippet":"…"}],"truncated":false,"id":"optional-64-chars"}
```

```json
{"v":1,"op":"search","decision":"block","reason":"dlp|length|state|rate|budget|judge|upstream|request","results":[],"truncated":false}
```

Kanbei dials host CID 2, port 7101, from inside its Firecracker VM. Firecracker
forwards that to `/var/lib/microvms/kanbei/notify.vsock_7101`, where
`search-relay.service` listens as `root:kvm`; the relay dials the search guest's
`/var/lib/microvms/search/notify.vsock` (`CONNECT 7024`) and pipes bytes both
ways. If the guest is down, the relay closes Kanbei's connection: a broken
channel, never an empty result. The batch port 7014 stays the verifier's ingest
path; the query API has its own port.

## Logs and viewer

The guest's `searchd` writes one JSON line per request to
`/var/log/search/search.log` (0600, tmpfs, rotated at 1 MiB) and to `journal+console`.
The console copy is the durable one: Firecracker's serial output is captured by
the root-only `microvm@search` journal on the host, which `kanbei-logs` tails.
The judge's `llama-server` output goes to `/var/log/search/judge.log`. Allowed
queries are logged verbatim, because they already left; blocked queries are
logged with length, rule and digest only. The host relay adds
`/var/log/kanbei-ingest/search-relay.log` (connection metadata and byte counts;
no payload).

Both are read through the touch-gated viewer:

```
/run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs
/run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs search
```

## Planted exfiltration suite

`tests/search/fixtures/cases.json` holds 32 planted cases: 19 DLP (provider
keys, emails, SSN/card/phone/account digits, hex and base64 blobs, high entropy,
keyword+value, a zero-width split), 6 instruction-smuggling cases, and 7 benign
questions. The runner (`tests/search/run_suite.py`) measures twice:

1. **DLP with the judge stubbed to `no`** — every DLP case must block and every
   benign case must pass, so a rule that matches everything cannot score 100%.
2. **DLP plus a deterministic judge double** — every smuggling case must block,
   DLP cases stay blocked and benign cases stay allowed.

Recorded thresholds (also the runner's constants):

| measurement | threshold | measured |
|---|---|---|
| DLP block (judge stubbed) | 100% | 19/19 (100%) |
| benign allow (judge stubbed) | ≥90% | 7/7 (100%) |
| judge double block | ≥95% | 6/6 (100%) |
| DLP block through the service | 100% | 19/19 (100%) |
| benign allow through the service | ≥90% | 7/7 (100%) |

The runner exits 1 below a threshold, and `checks.x86_64-linux.kanbei-search-suite`
runs it together with the unit tests. The double is a keyword check, not the
model: the suite proves the pipeline, the corpus and the floor. The real model's
block rate is model-gated and measured by hand (below).

## Residual leak

An admitted query is sent to TinyFish and is visible to that provider. The cap,
DLP and judge bound what can be carried per query and how often; they cannot
make the channel zero-bit, and `docs/kanbei-split.md` records the leak as
accepted. A query that passes every gate is still the largest payload Kanbei can
send: at most 100 characters, at most 20 per minute and 300 per day. A blocked
query does not leave the host, and its text is not duplicated into the log.

## Manual steps

1. **Kanbei's TinyFish key.** Mint a key dedicated to Kanbei at
   [agent.tinyfish.ai](https://agent.tinyfish.ai/api-keys); do not reuse the
   host's `tinyfish-api-key` (maki/nanobot keep their own). Stage it out of band
   as the existing ingest contract, at mode 0400 root:root:

   ```sh
   umask 077
   printf 'TINYFISH_API_KEY=%s\n' '<key>' > /tmp/ingest-search-env
   sudo install -m 0400 -o root -g root /tmp/ingest-search-env /run/secrets/ingest-search-env
   shred -u /tmp/ingest-search-env
   sudo stat -c '%a %U:%G %n' /run/secrets/ingest-search-env
   ```

   Rotating the key is stop-then-stage: `ingest-vm-secret-search.service` refuses
   to replace the image under a running guest. Stop `microvm@search`, re-stage
   `/run/secrets/ingest-search-env`, then start
   `ingest-vm-secret-search.service microvm@search`.

2. **Guardian model.** The guest has no NIC and the weights are not in the Nix
   store. Fetch them on the host, hash-checked against
   `modules/lib/search-models.json` (Q4_K_M, 1,545,303,040 bytes, sha256
   `c3c5373be0cf0de73ded2033e922c33bb77021a9953d2a81be0b978880a763da`):

   ```sh
   sudo nix shell nixpkgs#python3 -c \
     python3 modules/lib/kanbei-fetch-models.py \
       --manifest modules/lib/search-models.json \
       --dest /var/lib/search-model --uid 0 --gid 0
   ```

   `search-vm-model.service` verifies the size and sha256 again, builds
   `/var/lib/microvms/search-model/guardian.img` (ext4, read-only, 32 MiB larger
   than the file, `0440 root:kvm`) and records the digest in `guardian.img.sha256`.
   Replace the model by stopping `microvm@search`, refetching, and starting
   `search-vm-model.service microvm@search`.

   `search-vm-state.service` creates the 8 MiB writable limiter image
   (`/var/lib/microvms/search-state/state.img`, `0660 root:kvm`) once and never
   reformats it. The guest mounts it at `/var/lib/search`, so the rate/budget
   counters survive a restart. To reset a budget deliberately, stop
   `microvm@search`, delete `state.img`, and start it again.

3. **Enable and confirm.** With `kanbeiVm.enable` already on, flip
   `ingestVm.enable` (pinned off in `modules/hosts/smortress/default.nix`):

   ```sh
   sudo systemctl status search-vm-model search-vm-state search-relay
   sudo systemctl status microvm@search
   sudo journalctl -u 'microvm@search' -n 50 --no-pager
   sudo systemctl status ingest-proxy ingest-resolver
   sudo iptables -S ingest-search-in ingest-search-fwd
   ```

   The guest log shows `search-judge` loading the model and `searchd` listening on
   port 7024. A missing key or model keeps the guest down rather than starting a
   permissive service.

4. **Measure the real model.** The suite's judge is a double. Ask the real judge
   through the guest's own vsock, one request per line, then read the decision in
   the log:

   ```sh
   sudo nix shell nixpkgs#python3 -c python3 - <<'PY'
   import sys
   sys.path.insert(0, "modules/lib/search")
   import search_relay
   sock = search_relay.connect_vsock("/var/lib/microvms/search/notify.vsock", 7024)
   sock.sendall(b'{"v":1,"op":"search","query":"who wrote Dune"}\n')
   print(sock.recv(8192).decode())
   PY
   ```

   Record the model's block rate for the six smuggling fixtures and any benign
   false positive in this file when the model is first run on smortress.

5. **Viewer.** Every query and decision is root-only; read it through the
   absolute sudo wrapper (the touch is the human gate):

   ```sh
   /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs search
   ```

## Verification

Runs anywhere, no hardware or model:

```sh
nix build .#checks.x86_64-linux.kanbei-search-suite \
          .#checks.x86_64-linux.unit-tests \
          .#checks.x86_64-linux.kanbei-ingest-guards \
          .#checks.x86_64-linux.manual-steps-sync \
          .#checks.x86_64-linux.eval-nixos-smortress
nix run nixpkgs#python3 -- tests/search/run_suite.py
nix run nixpkgs#python3 -- -m unittest tests.test_search_gates tests.test_search_service tests.test_search_suite
```

The search guest's own toplevel evaluates through the host's `ingestVm.enable`
gate; a direct eval needs the same override the host uses:

```sh
nix eval --raw --impure --expr '
let f = builtins.getFlake (toString ./.); lib = f.inputs.nixpkgs.lib;
in (f.nixosConfigurations.smortress.extendModules {
  modules = [ { kanbeiVm.enable = lib.mkForce true; ingestVm.enable = lib.mkForce true; } ];
}).config.microvm.vms.search.config.config.system.build.toplevel.drvPath'
```

Hardware/model-gated: the real judge's latency and block rate, the relay's
end-to-end path from the Kanbei guest, and TinyFish accepting the dedicated key.

Recorded 2026-11-11 on smortress (code bar, no sudo): `format`, `statix`,
`deadnix`, `manual-steps-sync`, `kanbei-ingest-guards`, `kanbei-search-suite`,
`unit-tests` and `eval-nixos-smortress` build; the search guest toplevel and the
host toplevel with `ingestVm.enable` build; `tests/search/run_suite.py` reports
19/19 DLP blocks, 6/6 judge-double blocks and 7/7 benign allows with both judge
modes. Not run here: the real Guardian weights and an end-to-end query from the
Kanbei guest.
