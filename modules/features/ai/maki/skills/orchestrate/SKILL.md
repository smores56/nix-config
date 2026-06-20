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

- Use `model_tier="weak"` for cheap search, summaries, names, boilerplate, and
  simple edits.
- Use `model_tier="medium"` for normal implementation and moderate refactors.
- Use `model_tier="strong"` only for architecture, subtle bugs, critical review,
  or high-risk decisions.
- Maki caps child model tiers at the parent model's current tier.
- Each `task` starts fresh, so include paths, constraints, expected output, and
  whether edits are allowed.
- Ask subagents for concise `file_path:line_number` summaries, not code dumps.
