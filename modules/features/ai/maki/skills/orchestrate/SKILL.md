---
name: orchestrate
description: "Load before planning non-trivial coding work: multi-step, multi-file, ambiguous, risky, parallelizable, or research-heavy. Decompose, delegate with Maki's native task/batch tools, then synthesize and verify."
---

# Orchestrate

Use this workflow for non-trivial work. Do not use it for simple questions,
trivial lookups, or one-file mechanical edits.

## Workflow

1. Decide whether the request can be split into useful lanes. If not, do it
   directly.
2. Run read-only discovery first when context is missing: `task` with
   `subagent_type="research"`.
3. Delegate bounded implementation with `subagent_type="general"`. Put
   independent `task` calls in `batch`; keep dependent steps sequential.
4. Synthesize results yourself, resolve conflicts, verify, and give the user the
   integrated answer.

## Task Discipline

Maki over-delegates to `strong` by default. Bias the other way: strong is the
exception, not the baseline. Pick the cheapest tier that can plausibly succeed,
only escalate when you have a concrete reason.

- Default to `model_tier="weak"`. Use it for search, grep, glob, reads,
  summaries, names, boilerplate, mechanical edits, formatting, test runs, and
  anything where the steps are well-specified. Most subtasks belong here.
- Use `model_tier="medium"` only when the task needs real implementation
  judgment: multi-file refactors, non-trivial feature work, bug fixes that
  require diagnosis, or writing logic the weak model would likely get wrong.
- Use `model_tier="strong"` only as a last resort, for: architecture and system
  design, subtle or cross-file bugs, security review, high-risk irreversible
  changes, or synthesizing conflicting subagent results. If you reach for
  strong, name the specific reason in your planned approach before delegating.
- Escalation order: try weak first. Re-delegate at medium only if weak output is
  demonstrably insufficient — not preemptively "just in case." Re-delegate at
  strong only after medium has failed on a hard part.
- The parent (you) stays on its current model for planning, delegation, and
  synthesis — that is where strong reasoning earns its price. The workers should
  almost never be strong. Maki caps child tiers at the parent's tier, so weak
  workers are always available and cheap.
- Each `task` starts fresh, so include paths, constraints, expected output, and
  whether edits are allowed.
- Ask subagents for concise `file_path:line_number` summaries, not code dumps.
