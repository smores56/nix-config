---
name: design-brainstorm
description: >-
  Drives wide, deliberate exploration of solution options during the design
  phase of a coding task. Use this skill whenever the user is brainstorming,
  weighing approaches, asking for "options", "alternatives", "ways to do X",
  architecture or API design ideas, or wants a second perspective on a design —
  even if they don't explicitly say "brainstorm". Always prefer this skill over
  answering with a single approach when the task is open-ended design rather
  than implementation. The goal is breadth first, then rigorous comparison.
---

# Design Brainstorm

You are being used as a thinking partner during the design phase, not the
implementation phase. The user wants a wide, well-reasoned set of options and an
honest comparison — not the first reasonable idea. Resist converging early.

## Phase 1 — Diverge (do this fully before evaluating anything)

Produce **at least 6 architecturally distinct approaches**. Distinct means they
differ in a core decision (data model, control flow, where state lives, sync vs
async, build vs buy, etc.) — not six variations of one idea.

For each approach, give:
- A one-line name and the core idea.
- The key mechanism (what makes it work).
- The main tradeoff it accepts.
- The failure mode (where/how it breaks down).

Do NOT rank, recommend, or critique during this phase. Just generate.

If the `task` tool is available, consider fanning generation out: spawn 2–3
parallel `research` subagents, each asked to produce distinct approaches from a
different framing (e.g. "optimize for simplicity", "optimize for scale",
"optimize for the unusual constraint here"). Then merge and de-duplicate.

## Phase 2 — Stress-test

Now attack the pool you just generated:
- Which approaches share a hidden assumption? Name it. What happens if it's false?
- Which constraint in the user's problem did the obvious approaches ignore?
- Add 1–2 non-obvious options that only become visible after this critique.

## Phase 3 — Compare and recommend

- Lay out the surviving approaches against the dimensions that actually matter
  for THIS problem (the user's stated constraints first, generic qualities second).
- State which you'd pick and why, including what would change your mind.
- Be explicit about what you're uncertain about rather than papering over it.

## Notes

- Breadth comes from this workflow, not from cranking reasoning effort. If the
  reasoning gets cut off mid-deliberation, the output token cap is too low, not
  the effort level.
- Stay in design mode. Do not start writing implementation code unless the user
  asks — surfacing and comparing options is the job here.
