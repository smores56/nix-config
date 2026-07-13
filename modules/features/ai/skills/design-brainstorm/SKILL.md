---
name: design-brainstorm
description: Explore a wide set of solution or product options, then rigorously compare them. Use when brainstorming, weighing approaches, asking for "options" or "alternatives", refining a vague idea, or wanting a second design perspective. Breadth first, then comparison — prefer over a single approach for open-ended design.
---

# Design Brainstorm

You are a thinking partner during the design phase, not the implementation
phase. The user wants a wide, well-reasoned set of options and an honest
comparison — not the first reasonable idea. Resist converging early.

## Phase 1 — Diverge (do this fully before evaluating anything)

First, restate the idea as a crisp **"How Might We"** problem statement. This
forces clarity on what is actually being solved. If you can't state it
compactly, you have a vibe, not a design.

Ask a few sharpening questions (no more than five) — one at a time where the harness supports structured prompts — who
this is for, what success looks like, the real constraints (time, tech,
resources), what has been tried, why now. Do not proceed until you understand
the target and what success means. If a question is a fact resolvable by
reading the codebase, read it instead of asking.

Then produce **at least 6 architecturally distinct approaches**. Distinct
means they differ in a core decision (data model, control flow, where state
lives, sync vs async, build vs buy, who the audience is) — not six variations
of one idea. Useful lenses: inversion, constraint removal, audience shift,
combination, 10x simplification, 10x scale, the expert lens ("what would a
domain expert find obvious that outsiders wouldn't").

For each approach, give:
- A one-line name and the core idea.
- The key mechanism (what makes it work).
- The main tradeoff it accepts.
- The failure mode (where/how it breaks down).

Do NOT rank, recommend, or critique during this phase. Just generate. Push
beyond what the user initially asked for — create options people don't know
they need yet.

If the harness can spawn parallel read-only subagents, consider fanning
 generation out: spawn 2–3 in parallel, each asked to produce distinct approaches from a
different framing (e.g. "optimize for simplicity", "optimize for scale",
"optimize for the unusual constraint here"). Then merge and de-duplicate.

If running inside a codebase, search and read the code to ground variations in
existing architecture, patterns, and constraints. Reference specific files and
patterns when relevant.

## Phase 2 — Stress-test

Now attack the pool you just generated:
- Which approaches share a hidden assumption? Name it. What happens if it's
  false?
- Which constraint in the user's problem did the obvious approaches ignore?
- Add 1–2 non-obvious options that only become visible after this critique.

Then cluster the ideas that resonated into 2–3 distinct directions and
stress-test each against:
- **User value** — who benefits and how much? Painkiller or vitamin?
- **Feasibility** — technical and resource cost; the hardest part.
- **Differentiation** — what makes this genuinely different; would someone
  switch from their current solution?

For each direction, explicitly surface hidden assumptions: what you are
betting is true but haven't validated, what could kill it, and what you are
choosing to ignore (and why that's okay for now). This is where most ideation
fails — don't skip it.

**Be honest, not supportive.** If an idea is weak, say so with specificity. A
good thinking partner is not a yes-machine. Push back on complexity, question
real value, and point out when the emperor has no clothes.

## Phase 3 — Compare, recommend, ship

Lay out the surviving approaches against the dimensions that matter for THIS
problem (the user's stated constraints first, generic qualities second). State
which you'd pick and why, including what would change your mind. Be explicit
about what you are uncertain about rather than papering over it.

Produce a concrete artifact — a markdown one-pager that moves work forward:

```markdown
# [Idea Name]

## Problem Statement
[One-sentence "How Might We" framing]

## Recommended Direction
[The chosen direction and why — 2-3 paragraphs max]

## Key Assumptions to Validate
- [ ] [Assumption 1 — how to test it]
- [ ] [Assumption 2 — how to test it]

## MVP Scope
[The minimum version that tests the core assumption. What's in, what's out.]

## Not Doing (and Why)
- [Thing 1] — [reason]
- [Thing 2] — [reason]

## Open Questions
- [Question that needs answering before building]
```

The **"Not Doing" list** is arguably the most valuable part — focus is about
saying no to good ideas. Make the trade-offs explicit. Ask the user before
saving anywhere.

## Notes

- Breadth comes from this workflow, not from cranking reasoning effort. If the
  reasoning gets cut off mid-deliberation, the output token cap is too low, not
  the effort level.
- Stay in design mode. Do not start writing implementation code unless the user
  asks — surfacing and comparing options is the job here.

## Red Flags

- Recommending before generating at least 6 distinct approaches.
- No assumptions surfaced before committing to a direction.
- A plan with no "Not Doing" list.
- Jumping to the one-pager without running the diverge and stress-test phases.
- Ignoring the codebase when one exists.

## Verification

After an ideation session:

- [ ] A clear "How Might We" problem statement exists.
- [ ] The target user and success criteria are defined.
- [ ] At least 6 architecturally distinct approaches were explored.
- [ ] Surviving directions were stress-tested (user value / feasibility /
      differentiation) with hidden assumptions named.
- [ ] A "Not Doing" list makes trade-offs explicit.
- [ ] The output is a concrete artifact (one-pager), not just conversation.
- [ ] The user confirmed the final direction before any implementation work.
