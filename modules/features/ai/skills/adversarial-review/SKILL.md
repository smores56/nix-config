---
name: adversarial-review
description: Multi-persona adversarial review: parallel read-only subagents with orthogonal lenses cross-examine each other, then synthesize a consensus verdict. Use to red-team code or a plan before merge, or when self-review monoculture is a risk. Triggers: "adversarial review", "red-team this", "review from multiple angles".
---

# Adversarial Review

A single model reviewing its own output shares the author's blind spots and
drifts toward "LGTM". This skill breaks that monoculture: spawn several
read-only subagents with **orthogonal** lenses, make each defend or challenge
the others' findings, then synthesize a verdict from the consensus rather than
from any one voice.

The deliverable is a synthesized verdict. Do **not** make code changes here —
this is review, not implementation.

## Scope vs. Neighboring Skills

- **`doubt-driven-development`** is *in-flight*: one fresh-context reviewer per
  non-trivial decision while course-correction is cheap. Use it during work.
- This skill is *post-hoc*: a finished diff or a written plan gets a
  multi-persona red-team pass. Use it before merge/commit.
- **`code-review-and-quality`** is a lightweight single-pass five-axis review
  for quick checks. Use it for small diffs; escalate to this skill when the
  change is high-stakes or you suspect the single pass missed something.

## Step 1 — Determine the Target

Decide what is under review:

- A **code change**: the diff (`git diff`), a specific file, or a branch's
  commits. Gather full surrounding context — not just changed lines — so
  reviewers can trace call chains and authorization paths.
- A **plan/design**: a written proposal or design doc. Reviewers challenge
  whether the plan achieves its stated intent.

State the **intent** explicitly before spawning reviewers: what the author is
trying to achieve. Reviewers judge whether the work achieves that intent well,
not whether the intent is correct.

## Step 2 — Spawn Reviewers (parallel, isolated)

Spawn **three read-only subagents in parallel, each in isolated context**.
Each gets a single lens and **must not see the others' output**. Isolation is
the point — shared context produces correlated blind spots.

Each subagent prompt contains: the stated intent, its assigned lens (full
text below), the artifact (diff/plan), and the instruction:

> You are an adversarial reviewer. Find real problems, do not validate. Be
> specific — cite `file:line` and concrete failure scenarios. Rate each
> finding **high** (blocks ship), **medium** (should fix), or **low** (worth
> noting). Write findings as a numbered markdown list. If you cannot find a
> real issue after thorough examination, say so explicitly rather than
> inventing one.

### The Lenses (stay in your lane — do not duplicate the others)

**Auditor — correctness and logic.** Does this compute the right answer?
Edge cases, off-by-one, race conditions, state inconsistencies, unhandled
error paths, invariant violations, type-boundary leaks. The "will it actually
work" lens.

**Adversary — security and abuse.** What can a hostile caller or untrusted
input do? Auth/authz gaps, injection, trust-boundary crossings, data leakage,
prompt injection, unsafe deserialization, missing rate limits. Treat all
external data as hostile.

**Pragmatist — maintainability and design fit.** Will this survive contact
with reality? Coupling, circular dependencies, abstractions that don't earn
their cost, feature logic leaking into shared modules, missing tests for new
behavior, changes that relocate complexity instead of reducing it.

## Step 3 — Cross-Review (parallel, second round)

Re-spawn the same three lenses (in parallel), this time giving each the **full set
of round-1 findings**. Each must go on record about every finding:

- **Validate** findings it agrees with (and why).
- **Challenge** findings it thinks are wrong or overstated (and why).
- **Add** new findings the other lenses surfaced that it now sees.

This is the anti-anchoring round: each persona must defend a position visible
to the others. A finding only counts as solid if it survives challenge.

## Step 4 — Synthesize (deterministic, no extra model call)

Merge all findings and dedupe. Score each by how many personas support it and
whether it survived cross-review:

| Status | Meaning |
|---|---|
| **cross-validated** | Raised by ≥2 personas, or raised by one and validated by another in round 2 |
| **consensus** | Raised by one, unchallenged in round 2 |
| **disputed** | Raised by one, challenged by another in round 2 with no resolution |
| **solo** | Raised by one, no cross-talk at all |

Order findings by status (cross-validated → consensus → disputed → solo) then
by severity (high → medium → low).

## Step 5 — Render Judgment

You are the orchestrator. The reviewers are adversarial by design; not every
finding warrants action. Apply your own frame:

- Call out **false positives** — findings that mistake style for substance or
  ignore context the reviewers lacked.
- Call out **overreach** — findings that demand changes beyond the change's
  scope.
- State which findings you would accept and which you would reject, and why.

Produce a single verdict:

```
## Intent
<what the author is trying to achieve>

## Verdict: PASS | CONTESTED | REJECT
<one-line summary>

## Findings
<numbered, ordered by status then severity>
- **[severity]** description with file:line — Lens: <which> — Status: <scoring>
  - Recommendation: <concrete action, not vague advice>

## What Went Well
<1-3 things the reviewers found no issue with>

## Orchestrator Judgment
<which findings to accept / reject and why>
```

**Verdict logic:**
- **PASS** — no high-severity findings.
- **CONTESTED** — high-severity findings but reviewers disagree (disputed).
- **REJECT** — high-severity findings with cross-validated consensus.

Do not auto-fix. Hand the verdict to the user; let them decide what to act on.

## When NOT to Use

- Small, obviously-correct diffs where a single-pass `code-review-and-quality`
  pass suffices — the multi-persona overhead isn't worth it.
- You need in-flight course correction — use `doubt-driven-development`
  instead.
- There is no artifact yet — review needs something concrete to examine.

## Red Flags

- Reviewers that validate instead of finding problems ("looks good, maybe
  add tests").
- Skipping the cross-review round — that is the anti-anchoring step.
- Spawning reviewers that share context or see each other's round-1 output.
- Rubber-stamping the synthesis — re-read the artifact against each finding
  before scoring it.
- Treating the verdict as a mandate to auto-edit — this skill reviews, it does
  not implement.
- All three lenses reporting clean on a non-trivial change — re-spawn with a
  harder prompt; "no issues found" on complex code is usually a missed issue.
