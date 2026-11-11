# Photo triage runbook

Local Qwen scores every Immich photo and writes two albums, `triage-delete`
and `triage-review`. The pipeline never deletes assets: a human deletes from
`triage-delete`, and Immich's 30-day trash is the final net.

## Prerequisites

- The two Immich API keys from `docs/key-rotation.md` (read key and
  album-writer key), with `photoTriage.readKeyFile` and
  `photoTriage.albumKeyFile` set to their sops paths.
- The library is scanned and scored by the dedicated scoring server; the
  interactive `llama-cpp.service` is down for the whole window.
- `systemctl status llama-cpp-photo-triage.service` and the Immich relay are
  healthy after the window opens.

## Run

```
sudo systemctl start photo-triage.service      # opens the window and runs
photo-triage-admin status                      # or: sudo -u photo-triage ...
photo-triage-admin benchmark --history
sudo journalctl -u photo-triage.service -f
```

The orchestrator scans, scores pending assets, analyzes previews and duplicate
groups, and writes
`/var/lib/photo-triage/triage-membership-<scan>.json`. It stops after `decide`;
albums are never written automatically.

The scan covers timeline-visible, non-trashed images **including every member of
a stack**: Immich compiles `withStacked: false` to `asset.stackId IS NULL`, which
drops stack primaries too, so the scan sends `withStacked: true`. Archived,
hidden and locked assets stay out of the scan through those Immich filters; the
client does not re-check visibility locally.

The scan also reads Immich's stack list (`GET /api/stacks`, so the read key needs
`stack.read`) and marks each stack's primary. Flags are stored per scan
generation, so unsticking a photo clears its protection downstream while an
older generation keeps the flags it was analyzed with. The export reports
`counts.stack_primaries`. A primary is
preferred as keeper while its own verdict is `keep`, and it is never proposed for
`triage-delete`, even when the model flags it; a primary without a `keep` verdict
stays protected and the group falls back to a trusted keeper. `decide` refuses a
scan that never imported stacks, so a pre-upgrade generation cannot be decided
without protection.

Non-primary stack members are scored and grouped like any other duplicate. A
grouped member is proposed for `triage-delete` only when its group keeper is
scored, current and trustworthy; byte-identical copies additionally need matching
checksums and previews, and near duplicates additionally need the model to call
the member defective. A non-primary frame the model flags on its own still reaches
`triage-delete`, so review the album as usual.

Downtime during the window: maki, Open WebUI, secret-sweep, and the LLM tunnel.
The scoring server owns the GPU; `llama-cpp.service` has
`ConditionPathExists=!` on `/run/photo-triage/maintenance` and cannot start.

`sudo systemctl stop photo-triage.service` is resume-safe: each start scans
metadata again (cheap) and reuses completed previews and scores, so only
missing work runs. A restart after `decide` starts a new scan generation, so
redo the calibration before syncing albums. `photo-triage-admin orchestrate
--scan-id <scan>` pins an existing complete generation. The maintenance unit
restores `llama-cpp.service` on stop or failure; if three starts fail inside
24 hours, run `systemctl reset-failed photo-triage.service` before retrying.
The unit is bounded by `RuntimeMaxSec=7 days`.

## Skipped assets

An asset that cannot be scored is skipped for that scan generation with a
`reason` and a short structural `detail`. `photo-triage-admin status` reports
`skipped_reasons` (counts per reason) and `skipped_details` (reason, then detail,
then count). Each reason keeps its ten commonest details and rolls the rest into
`(other)`; skips recorded before this schema read `detail=unknown` until they
are retried. When a scoring run skips anything it ends with one aggregate
`photo-triage skips` warning carrying per-generation totals, not per-asset lines.

The detail never carries the model's prose or the server's response body.
Zero-status model errors are the client's own text (for example
`hit max_tokens (max_tokens=512, completion_tokens=512)`); a peer-controlled
transport error reads `model http=0 class=transport`.

Two model habits are repaired instead of skipped. A repeated defect entry is
de-duplicated. A confidence outside 0-1, or exactly 1 (certainty and 1% on a
0-100 scale are indistinguishable), is recorded as 0 and the reply is routed to
`review`, so a repaired number can never justify a delete. Runs report
`repaired_defects` and `repaired_confidence`; duplicate JSON keys are rejected
outright.

- `model`: the server rejected the request (non-transient errors skip at once),
  with `model http=<status> class=<name>` where name is `context-overflow`,
  `image`, `template`, `grammar` or `other`; or the reply stopped at
  `max_tokens`.
- `schema`: the reply was not the verdict JSON after three attempts; the detail
  separates a short prose reply (`len=1-63, braces=none`) from a truncated one
  (`braces=unbalanced`). Only the replies that are not repairable land here.
- `preview`: Immich did not return a thumbnail (three attempts for transient
  errors; `immich http=<status>` or `immich transport`), or the bytes did not
  decode (`preview too-large` / `preview decode`).
- `type`: videos, which v1 never scores. They carry the Immich type as the
  detail and are excluded from requeue.

A new scan generation retries every previously skipped asset, because skip state
is per generation and only completed scores survive. To retry inside an existing
generation, fix the cause first, then requeue and rerun with the generation
pinned:

```
photo-triage-admin requeue --scan-id <scan> --reason model
photo-triage-admin orchestrate --scan-id <scan>
```

`orchestrate --scan-id` refuses a partial scan; finish it or start a new
generation instead. Requeue clears the detail and marks the generation's
analysis stale (a requeue that matches nothing leaves it alone), so the rerun
recomputes preview metrics and duplicate groups before deciding. Deciding again
creates a new decide run, which invalidates any existing calibration sign-off:
`status.calibration.passed` turns false and the report must be redone before
syncing albums.

## Review and sign-off

1. Inspect the export's `delete`, `review`, `keep` and per-cluster counts:
   `jq '{counts, tiers, clusters, cap}' /var/lib/photo-triage/triage-membership-<scan>.json`.
2. Build the calibration sample and publish its albums:
   `photo-triage-calibration-publish --scan-id <scan> --publish`.
3. Label the `photo-triage-dev` / `photo-triage-heldout` albums in Immich and
   import the labels (a JSON object of asset id to `keep`/`delete`):
   `photo-triage-calibration labels --file labels.json --replace`.
4. Run the held-out report; it exits nonzero when the go/no-go fails:
   `photo-triage-calibration report --scan-id <scan> --min-labelled 30`.
   The default rule is zero false deletes on the held-out set; use
   `--max-false-rate` only if a bound was agreed before the pilot.
5. Only a passing report for the same decide run and policy fingerprint lets
   `photo-triage-albums sync` write the albums:
   `photo-triage-albums sync --scan-id <scan> --dry-run`, then `sync`.
6. Delete in the Immich UI from `triage-delete`; use `triage-review` to feed
   labels back into the next run.

## Recovery

- **Model or GPU failure**: the run exits nonzero, the unit alerts through
  `cloudflare-email@`, the maintenance unit restores the interactive model,
  and the next start resumes.
- **Immich outage**: scan/analyze fail transiently; restart the run when
  Immich is healthy. Nothing is lost; completed scores and previews are reused.
- **Partial scan**: a new start scans again (metadata only) and reuses scores.
- **Stale export**: `decide` writes a new run id; `albums sync` refuses any
  export that is not the latest complete decide run for the latest complete
  scan.
- **Album drift** (a human edited an album): `albums sync` reports a
  `count_mismatch`; delete that album in Immich and rerun so it is recreated
  empty. Membership is tracked locally because Immich 3.0.3's album DTO has no
  asset list.
- **Tuning**: labels from `triage-review` and the held-out report feed the next
  policy revision; never lower a threshold without a new passing report.
