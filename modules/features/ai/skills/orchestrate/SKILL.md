---
name: orchestrate
description: Load before planning non-trivial coding work: multi-step, multi-file, ambiguous, risky, parallelizable, or research-heavy. Decompose, delegate, synthesize, and verify.
---

# Orchestrate

Use this workflow for non-trivial work. Do not use it for simple questions, trivial lookups, or one-file mechanical edits.

## Workflow

1. Decide whether useful independent lanes exist. If not, work directly.
2. Run read-only discovery first when context is missing.
3. Delegate bounded implementation only after the goal, constraints, paths, and acceptance checks are clear.
4. Run independent research or implementation tasks in parallel when the harness supports it.
5. Synthesize results yourself, resolve conflicts, verify, and give the user the integrated answer.

## Delegation discipline

- Prefer the cheapest model that can plausibly succeed.
- Use weak/fast agents for search, grep, reads, summaries, naming, boilerplate, mechanical edits, formatting, and test runs.
- Use mid-tier agents for multi-file refactors, diagnosis, non-trivial feature work, and logic that needs implementation judgment.
- Use the strongest model only for architecture, subtle cross-file bugs, security review, high-risk changes, or conflicting results.
- Escalate only after cheaper output is concretely insufficient.
- Each delegated task starts fresh. Include paths, constraints, expected output, verification commands, and whether edits are allowed.
- Ask delegated agents for concise summaries with `file_path:line_number` references, not large code dumps.
