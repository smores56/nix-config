---
name: review
description: Deep review of a diff, branch, or plan — parallel adversarial lenses with cross-validation, then fix what survives. Triggers "review this", "big code review", "red-team this", before merging high-stakes changes.
---

# Review

A single model reviewing its own output shares the author's blind spots and
drifts toward "LGTM". This skill breaks that monoculture: read-only
subagents with orthogonal lenses cross-examine the work, findings must
survive challenge, then the main session fixes what is real.

## Scope

Reviews a concrete artifact — a diff (`git diff`), a branch, a file, or a
written plan. Small obviously-correct diffs do not need this skill; use it
for non-trivial changes, high-stakes areas (security, auth, data, infra), or
when you suspect the easy pass missed something.

## Step 1 — Frame the intent

State what the author is trying to achieve. Reviewers judge whether the work
achieves that intent, not whether the intent is correct. Gather full context
around the artifact — reviewers must be able to trace call chains and
authorization paths, not just changed lines.

## Step 2 — Round 1: parallel isolated lenses

Spawn three read-only subagents in parallel, each in isolated context, each
with one lens. Isolation is the point — shared context produces correlated
blind spots.

Each subagent receives the stated intent, its lens, the artifact, and:

> You are an adversarial reviewer. Find real problems, do not validate. Be
> specific — cite `file:line` and concrete failure scenarios. Rate each
> finding **high** (blocks ship), **medium** (should fix), or **low** (worth
> noting). Numbered list. If you cannot find a real issue after thorough
> examination, say so explicitly rather than inventing one.

**Auditor — correctness.** Edge cases, off-by-one, race conditions, state
inconsistencies, unhandled error paths, invariant violations. Also the
tests: do they exist, do they test behavior rather than implementation,
would they catch a regression.

**Adversary — security and abuse.** What can a hostile caller or untrusted
input do? Auth/authz gaps, injection, trust-boundary crossings, data
leakage, secrets in code or logs, external data used without validation.

**Pragmatist — maintainability and fit.** Coupling, abstractions that
don't earn their cost, feature logic in shared modules, near-duplicates of
existing canonical helpers, changes that relocate complexity instead of
reducing it, dead code left behind.

## Step 3 — Round 2: cross-review

Re-spawn the same three lenses in parallel, each with the full set of
round-1 findings. Each must go on record for every finding: **validate**
(agree, why), **challenge** (wrong or overstated, why), or **add** (new
findings the others surfaced). A finding only counts as solid if it survives
challenge.

## Step 4 — Synthesize

Merge and dedupe. Score each finding:

| Status | Meaning |
|---|---|
| **cross-validated** | raised by ≥2 lenses, or raised once and validated in round 2 |
| **consensus** | raised once, unchallenged in round 2 |
| **disputed** | challenged without resolution |
| **solo** | no cross-talk |

Order by status, then severity. You are the orchestrator: call out false
positives (style mistaken for substance) and overreach (beyond the change's
scope), with your reasons.

## Step 5 — Fix

The main session applies fixes — full context lives here, not in a subagent.

- **Local, mechanical findings** — bugs, security holes, dead code,
  simplifications — fix directly, one at a time, tests after each
  (`test-driven-development` where behavior changes). Simplification
  preserves behavior exactly: understand why code exists before removing it
  (Chesterton's fence), match project conventions, never weaken error
  handling to "clean up", and don't refactor code outside the change's
  scope.
- **Design-level or disputed findings** — surface to the user with your
  recommendation before touching anything.

Report at the end:

```
## Review: [artifact]

### Verdict: PASS | CONTESTED | REJECT
(one line — PASS: no surviving high-severity findings;
CONTESTED: high-severity but disputed; REJECT: cross-validated high-severity)

### Findings
- **[severity]** description with file:line — Lens — Status
  - Fixed: [what changed]  or  Rejected/deferred: [why]

### Verification
(tests/build run, what passed)
```

## Red Flags

- Reviewers that validate instead of finding problems
- Skipping round 2 — that is the anti-anchoring step
- Subagents sharing context or seeing each other's round-1 output
- Rubber-stamping the synthesis — re-read the artifact against each finding
- All three lenses clean on a non-trivial change — re-spawn with a harder
  prompt; "no issues" on complex code is usually a missed issue
- Fixing disputed design-level findings without asking
- "Simplifications" that change behavior or weaken errors
- A refactor that moves complexity around instead of making concepts
  disappear
