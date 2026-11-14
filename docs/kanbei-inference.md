# Kanbei inference lanes

The `kanbei` guest's llama.cpp lanes (`smores56/sdlc#585`, part of #509): one GPU chat lane
and two CPU retrieval lanes, all loopback-only. The guest itself, its GPU passthrough and its
LUKS volume are [`docs/kanbei-vm.md`](kanbei-vm.md); the threat model is
[`docs/kanbei-split.md`](kanbei-split.md).

| Piece | File |
|---|---|
| pool shape, flags, VRAM math (one attrset) | `modules/lib/kanbei-inference.nix` |
| systemd units, GPU gate, hardening | `modules/nixos/kanbei-inference.nix` |
| model path contract (`/var/lib/kanbei/models/llama-models.json`) | `modules/lib/kanbei-models.json` |
| fetch + hash check | `modules/lib/kanbei-fetch-models.py` |
| eval harness (stdlib only) | `tests/inference/` |
| operator download/verify steps | `docs/manual-steps.md` ("Kanbei private-data VM", step 5) |

The model files are **not** in the Nix store and are not downloaded by a build. Everything
below is configuration and procedure; the numbers are computed, not measured, because Immich
triage still owns the 3090. The eval harness is what turns them into measurements after the
cutover.

## Hardware and model facts

| Fact | Value | Source |
|---|---|---|
| Card | RTX 3090, **24,576 MiB** VRAM | `modules/nixos/kanbei-vm.nix` (`10de:2204`) |
| Guest RAM | 8,192 MiB | T10 (`microvm.mem = 8192`) |
| Guest vCPU | 8 (4 physical cores with SMT) | T10 |
| Weights | `RVN-IQ4_XS-multilingual.gguf`, **15,082,506,784 B = 14,384 MiB** | model manifest |
| Layers | 64, every 4th full attention → **16 full-attention, 48 linear-attention** | `unsloth/Qwen3.8-27B-GGUF` `text_config` |
| KV shape | 4 KV heads × 256 head dim | same |
| Linear state | 48 layers × (48×128 values) × 128 key dim, f32 | same |
| Train context | 262,144 | same |

`RVN-IQ4_XS-multilingual.gguf` is the MTP-free quant; the `-mtp.gguf` variants carry a
one-layer MTP head this lane deliberately does not use, so no `--spec-*` flag is passed
(asserted in the module). The vision projector is not used at all.

## KV and VRAM math

**Per-token KV.** Only the 16 full-attention layers store KV:

```
2 (K and V) × 16 layers × 4 heads × 256 dim = 32,768 elements/token
q8_0 = 34 bytes per 32 elements (32 int8 + one f16 scale)
32,768 × 34 / 32 = 34,816 bytes/token = 34 KiB/token
```

**Recurrent state.** The 48 linear-attention layers keep a per-sequence state, not a
per-token cache: `48 × 48 × 128 × 128 × 4 B = 144 MiB` per slot, **576 MiB** for four slots.
That is charged once per lane, and it is why the idle-slot cache matters: dropping a slot
throws the state away and the next request re-processes its prefix.

**Pool sizes** (`modules/lib/kanbei-inference.nix`, `lanes`):

| Pool | KV | + weights | + recurrent | + overhead | Total | Headroom |
|---|---|---|---|---|---|---|
| 32k (one short lane) | 1,088 MiB | 14,384 | 144 | 1,200 | 16,816 | 7,760 |
| 128k (the long lane alone) | 4,352 MiB | 14,384 | 144 | 1,200 | 20,080 | 4,496 |
| **160k (configured)** | **5,440 MiB** | 14,384 | 576 | 1,200 | **21,600** | **2,976** |
| 224k (1×128k + 3×32k) | 7,616 MiB | 14,384 | 576 | 1,200 | 23,776 | 800 |

224k *arithmetically* fits, but 800 MiB is inside the noise of CUDA context growth, the
compute buffer and a 2048-token batch; one extra MiB anywhere and the load fails. 160k is the
realistic ceiling and is what the module configures. The 224k row is kept in the same attrset
(`budgetAtNominal`) so the trade-off is auditable, not folklore. The module asserts
`budget.fits` and fails evaluation if the configured pool ever exceeds 24,576 MiB.

## Reading the effective configuration

The guest renders the whole lane attrset to `/etc/kanbei/inference.json`, so the numbers can be
printed without reading prose or starting the service (the flag uses `mkForce` because
`modules/hosts/smortress/default.nix` pins it off until the cutover):

```sh
nix eval --raw --impure --expr '
let f = builtins.getFlake (toString ./.); lib = f.inputs.nixpkgs.lib;
    c = f.nixosConfigurations.smortress.extendModules { modules = [ { kanbeiVm.enable = lib.mkForce true; } ]; };
    g = c.config.microvm.vms.kanbei.config.config;
in g.environment.etc."kanbei/inference.json".text' |
  jq '{ctx: .lanes.poolTokens,
       kv_unified_per_slot: .lanes.perSlotCap,
       per_slot_flag_supported: .lanes.perSlotCapSupported,
       kv_bytes_per_token: .lanes.kvBytesPerToken,
       total_mib: .budget.totalMiB,
       headroom_mib: .budget.headroomMiB}'
```

```
{ "ctx": 163840, "kv_unified_per_slot": 131072, "per_slot_flag_supported": false,
  "kv_bytes_per_token": 34816, "total_mib": 21600, "headroom_mib": 2976 }
```

The same command without `jq` prints the emitted flags and all three lanes' argv (`.args`).
The module's assertions fail *evaluation* when the budget no longer fits or a `--spec-*` flag
appears.

## The lanes

Upstream llama.cpp has one `-c` and one `-np` per server: there is no supported way to give
slot 0 128k and slots 1–3 32k. The closest shape, and the one configured, is:

```
--ctx-size 163840 --parallel 4 --kv-unified --cache-type-k q8_0 --cache-type-v q8_0
```

With `-kvu`, the four slots share **one** 160k-token KV buffer (breadth-first), and each slot
may grow to the whole pool (the server logs `n_ctx_slot = 163840, kv_unified = 'true'`). So
the nominal 1×128k + 3×32k request pattern (229,376 tokens) cannot be resident at once. What
each lane actually gets:

| State | Long lane | Each short lane |
|---|---|---|
| long lane alone | 131,072 | — |
| long lane + one short resident | 131,072 | 32,768 |
| long lane + two shorts resident | 98,304 | 32,768 |
| long lane + three shorts resident | 65,536 | 32,768 |
| three shorts resident, long lane arrives | 65,536 | 32,768 |
| long lane resident, three shorts share the rest | 131,072 | **10,922** |

So "the long lane gets 128k" holds while at most one short lane is resident; with all three
loops active it gets 64k and the loops share 32k (10,922 tokens each). Requests that do not
fit are queued by the server, not rejected by the allocator. The eval measures exactly this:
it never treats queueing as failure, only OOM, an error response, or a dead endpoint.

`--slot-save-path /var/lib/kanbei/kv-cache` is the explicit disk spill for a slot that is
going away; `--cache-idle-slots` + `--cache-ram 4096` keeps idle slots (and their recurrent
state) in a RAM prompt cache when a new task arrives. `--cache-idle-slots` is a no-op without
`--cache-ram` (the server logs "requires --cache-ram, disabling").

## Flags, one by one

Chat lane (`chatArgs` in `modules/lib/kanbei-inference.nix`):

| Flag | Why |
|---|---|
| `-c 163840 -np 4 -kvu` | the unified pool and its four slots, sized above |
| `-ctk q8_0 -ctv q8_0` | halves KV versus f16; the 34 KiB/token figure above |
| `-fa on` | flash attention is required for the quantised KV path |
| `-ngl all` | every layer on the 3090; the CPU has no room for any of it |
| `--ctx-checkpoints 8 --checkpoint-min-step 8192` | hybrid prefix reuse: checkpoint the non-rollbackable state at most every 8k tokens, 8 per slot |
| `-cram 4096 --cache-idle-slots` | keep idle slots (KV + recurrent state) in RAM for the next request |
| `--slot-save-path /var/lib/kanbei/kv-cache` | explicit slot spill; needs `/slots`, so the endpoint stays enabled |
| `--no-context-shift` | a full pool queues; it never silently drops the head of a 128k prompt |
| `--jinja` | tool calling: nanobot sends a `tools` array and only the checkpoint's own Jinja template emits the tool-call tokens the server parses back into `tool_calls` |
| no `--spec-*` | MTP is off: the file is the MTP-free quant and no speculative state is allocated |
| `--host 127.0.0.1 --port 8090` | no NIC in the guest; loopback only |
| `--metrics` | the eval reads `llamacpp:kv_cache_usage_ratio` and `requests_processing` |

Embeddings: `--embeddings --pooling last -c 8192 -np 4 -t 4 -ngl 0`, model
`Qwen3-Embedding-0.6B-Q8_0.gguf`. Rerank: `--reranking -c 4096 -np 4 -t 4 -ngl 0`, model
`bge-reranker-v2-m3-Q8_0.gguf`; **no** `--pooling` is passed because the reranker GGUF carries
rank pooling in its metadata, and forcing `last` would score the wrong vector. `-t 4` is the
guest's physical core count (8 vcpu with SMT), so the CPU lanes do not steal the chat lane's
schedulable vCPUs.

## The `--kv-unified-per-slot` gap

Upstream `llama.cpp` master (after nixpkgs `b10063`) has:

```
--kv-unified-per-slot N   context limit per parallel slot
                          (when set without -c, the shared pool is sized to n_parallel*N)
```

The pinned build (`modules/lib/llama-cpp-models.nix`, fork `z-lab/llama.cpp-fork@1deefcca`,
version `dflash2-1deefcca`) does **not** have it; its `--help` lists only
`-kvu, --kv-unified, -no-kvu, --no-kv-unified`. Passing the newer flag to this binary would
abort the server at startup, so the lane config keeps the value `perSlotCap = 131072` and
`perSlotCapSupported = false`, emits `--kv-unified`, and the eval prints the cap next to the
flag support bit:

```json
"lanes": { "perSlotCap": 131072, "perSlotCapSupported": false, "poolTokens": 163840, ... }
```

Behaviour at this pin is the unified pool (the cap is advisory: one slot can still take the
whole pool when the others are idle). When the pin moves to a revision with the flag, set
`perSlotCapSupported = true` and add `--kv-unified-per-slot <perSlotCap>` in `chatArgs`; the
eval JSON already carries the value.

## Services and hardening

`modules/nixos/kanbei-inference.nix`, imported by the guest config in `kanbei-vm.nix`:

| Unit | Role |
|---|---|
| `kanbei-inference-models.service` | oneshot: creates `/var/lib/kanbei/models` and `/var/lib/kanbei/kv-cache` on the LUKS mount and installs the manifest |
| `kanbei-inference-gpu.service` | oneshot gate: waits up to 240 s for `/dev/nvidiactl`, `/dev/nvidia0`, `/dev/nvidia-uvm` and `nvidia-smi` reporting ≥ 24,000 MiB, then stays active; `Restart=on-failure` |
| `kanbei-chat.service` | the GPU lane; `Requires` + `After` the two oneshots |
| `kanbei-embeddings.service` | CPU lane, `MemoryMax=2G` |
| `kanbei-rerank.service` | CPU lane, `MemoryMax=1536M` |

All three servers:

- `User=kanbei`, `uid/gid 1000` — the identity `kanbei-vm.nix` maps to the host `vault` user
  on the virtiofs shares, so a later payload tool keeps the same mapping. Nothing here writes
  a share.
- `RequiresMountsFor=/var/lib/kanbei` — the LUKS mount is a dependency, not an assumption.
- `Restart=always`, `RestartSec=5s`; `StartLimitBurst=5` per 30 min for the chat lane.
- `ReadOnlyPaths=/var/lib/kanbei/models`, `ReadWritePaths=/var/lib/kanbei/kv-cache` under
  `ProtectSystem=strict`; `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`,
  `ProtectKernel{Tunables,Modules,Logs}`, `ProtectControlGroups`, `RestrictNamespaces`,
  `RestrictAddressFamilies=AF_INET{,6},AF_UNIX`, `LockPersonality`, `UMask=0027`.
- Three keys stay at systemd's defaults **on purpose** and the module says so:
  `PrivateDevices=false` (CUDA opens `/dev/nvidia*`), `MemoryDenyWriteExecute=false` (the
  driver's mappings), `PrivateNetwork=false` (loopback is the listener; a private netns would
  still have `lo` but hides the device-side relay contract T14 will wire).
- No `SystemCallFilter`: CUDA's `mmap`/`ioctl`/NUMA calls are not safely covered by
  `@system-service`, and a startup failure here is not debuggable without the GPU.

`/etc/kanbei/inference.json` is the rendered `effective` attrset; it is the file the eval
commands below read.

## Model path contract

`/var/lib/kanbei/models` is on the LUKS volume, owned `root:kanbei 0750`; the files are
`0640 root:kanbei`. `llama-models.json` is the manifest:

```json
{"models": {"chat": {"repo": "...", "file": "...", "size": 15082506784,
                     "sha256": "b615856b...5aa4"}, ...}}
```

Source of truth: `modules/lib/kanbei-models.json` (same file installed into the guest).
`modules/lib/kanbei-fetch-models.py` downloads from Hugging Face, checks `Content-Length`,
streams to a `.part` file, verifies size **and** sha256, and only then renames it into place;
a mismatch removes the partial and exits 2. `--check` verifies without network access.
Downloading is an operator step (the guest has no NIC and the volume is locked while the guest
runs) — see `docs/manual-steps.md`, step 5 of "Kanbei private-data VM".

## Eval harness

`tests/inference/`, Python standard library only. Every script exits **0 with `SKIP: ...`**
when the endpoint is absent or a manifest file is missing, so the suite is safe to run before
the cutover:

| Script | What it does | PASS |
|---|---|---|
| `lane_fit.py` | four concurrent requests at 128k/32k/32k/32k; samples `/metrics` and the chat cgroup's `oom_kill` | all four HTTP 200 within `--timeout`, `oom_kill` unchanged, `/health` ok afterwards. Queueing is reported, not failed. |
| `long_context_recall.py` | needle at the chosen depth of a 128k prompt, greedy answer | the answer contains the needle phrase (case/punctuation normalised) |
| `quality_sample.py` | the same greedy prompts to the q8_0 lane and to an f16-KV reference server | exact-match ≥ 0.90 and mean `difflib` similarity ≥ 0.98 |
| `run_all.py` | all three, with a summary | every step passes or skips |

Commands:

```sh
# inside the guest (console shell): the guest ships the harness and python3
kanbei-inference-eval                      # all three checks
kanbei-inference-eval --json-dir /var/lib/kanbei/kv-cache/eval

# from the host, over the relay once T14 wires it
just inference-eval
just inference-eval --chat-url http://127.0.0.1:8090 --json-dir /tmp/kanbei-eval
```

The f16 reference server for `quality_sample.py` needs the whole card, so stop the chat lane
first and bring it back afterwards:

```sh
sudo systemctl stop kanbei-chat.service
sudo -u kanbei llama-server \
  --model /var/lib/kanbei/models/RVN-IQ4_XS-multilingual.gguf \
  --host 127.0.0.1 --port 8093 --ctx-size 40960 --parallel 1 \
  --cache-type-k f16 --cache-type-v f16 --flash-attn on --n-gpu-layers all --no-slots
# in another console:
kanbei-inference-eval --fp16-url http://127.0.0.1:8093
sudo systemctl start kanbei-chat.service
```

Budget for the f16 server: 14,384 MiB weights + 2,560 MiB KV (40,960 × 64 KiB) + 144 MiB
state + ~1,200 MiB overhead ≈ 18.3 GiB, so it fits *instead of* the chat lane, not beside it.

### Go/no-go thresholds (recorded before the first run)

- **Lane fit**: 4/4 200, no `oom_kill` delta, endpoint healthy after. The long lane must be
  200 — a 128k failure is a no-go for the lane shape even if the shorts pass.
- **Recall at 128k**: needle found. A miss at depth 0.5 is a no-go; try depths 0.1 and 0.9
  (`--depth`) before blaming the pool.
- **Quality**: exact ≥ 0.90, similarity ≥ 0.98 on 8 prompts at temperature 0. Below either,
  keep f16 KV and re-check VRAM (f16 at 160k is 10,880 MiB of KV; the pool has to drop to
  ~112k to fit).
- Record the JSON (`--json-dir`) in the ticket before calling the lane done; a run without
  recorded output is not evidence.

A first run also has to show `nvidia-smi` with no Xid errors and `systemctl show
kanbei-chat -p NRestarts` unchanged. The harness cannot read `dmesg`; that check is manual.

## Known upstream constraints (hybrid Qwen, KV and checkpoints)

At the pinned fork revision (`tools/server/server-context.cpp`):

1. **Checkpoint restore can fall back to full re-processing on hybrid/recurrent models.** The
   server logs `forcing full prompt re-processing due to lack of cache data (likely due to SWA
   or hybrid/recurrent memory)` and replays the prompt. For this model that means the
   linear-attention state was not part of the saved checkpoint, so prefix reuse is best-effort:
   time-to-first-token after a checkpoint hit is not guaranteed to be small.
2. **Checkpoints are created only for completion tasks** (`do_checkpoint` is gated on
   `SERVER_TASK_TYPE_COMPLETION`), and never after an mtmd chunk. Text-only chat completions
   qualify; a future vision projector would not.
3. **`[TAG_CHECKPOINTS_FIX_POS_MIN]` is an upstream open fix**: the checkpoint's saved range
   can be recorded incorrectly, so a restore may land earlier than the requested position.
   The server compensates by re-processing; it does not corrupt KV.
4. **Idle-slot clearing is only meaningful with unified KV.** `try_clear_idle_slots()` returns
   immediately when `kv_unified` is false; with this lane's `-kvu` it clears a finished slot
   and the RAM cache keeps a copy (which is where the 4 GiB `--cache-ram` goes).
5. **`--cache-idle-slots` silently disables itself when `--cache-ram` is 0** (server logs the
   warning). The lane sets 4096, so the flag is live.
6. **`--no-slots` would break `--slot-save-path`**: save/load are `/slots` endpoints. The
   lane keeps slots exposed on loopback; that is part of why the listener must stay
   loopback-only (a slot read returns prompt text).

## Residuals

- The lanes have no authentication. The guest has no NIC and all three bind `127.0.0.1`; the
  only future ingress is a vsock relay the host owns. A same-uid process inside the guest can
  query the lanes and read prompts through `/slots` — the guest runs one payload uid by design.
- The 4 GiB prompt cache plus the two CPU lanes compete with the model's page cache in 8 GiB
  of guest RAM. A full cache plus both CPU lanes is ~7.5 GiB of ceilings, so a cache-heavy
  workload can push the chat lane into reclaim; the eval reports prefill throughput, which is
  where that would show. Widening guest RAM is a T10 change (`microvm.mem`).
- `q8_0` KV is a quality trade, bounded by the quality-sample thresholds above; the result is
  unmeasured until the GPU is free.
- The pinned binary has no `--kv-unified-per-slot`, so the per-slot cap is advisory (above).
- 128k prefill on a hybrid 27B writes a 160k pool; the first request after boot is the
  slowest (weights stream from LUKS through 8 GiB of RAM), which is why `TimeoutStartSec=2h`
  and the eval's 1800 s per-request timeout are generous.
