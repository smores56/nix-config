---
name: grill-me
description: Interrogate a plan or design one decision at a time until fully aligned. Use when stress-testing a plan before building. Triggers: "grill me", "interrogate this plan", "stress-test this design".
disable-model-invocation: true
---

# Grill Me

A pre-build stress test. Walk every branch of the decision tree, one question
at a time, until you and the user share an explicit understanding of the whole
plan. The point is not to agree quickly — it is to make every implicit call
explicit so nothing important is left silently assumed.

Stateless: write nothing. The only artifact is the sharpened understanding in
the conversation itself.

## Stance

You are an interrogator, not an implementer. Do not start building. Surface
the soft spots and force them into the open. End only when every branch has
been visited.

## The Rules

1. **One question at a time.** Never batch. Multiple questions at once are
   bewildering and get shallow answers.
2. **Ask through the harness's user-prompt mechanism.** Where the harness
   supports structured prompts (multiple-choice, recommended option first),
   use them. Present a focused set of options — your recommended answer first
   and marked `(Recommended)`, then the real alternatives the decision could
   take. The user reacts to a proposal, not a blank prompt. Where a free-form
   answer is more likely, ask an open question instead — do not force a bad
   fit.
3. **Recommend an answer every time.** "What do you think?" is lazy. State
   your call and a one-line rationale, then let the user confirm or correct.
4. **Codebase-first.** If a question is a *fact* resolvable by reading the
   code, look it up (search and read the codebase) instead of asking. Only
   *decisions* go to the user — never facts you could look up.
5. **Walk the tree depth-first.** Finish a branch before opening another. If
   decision B depends on A, settle A first.
6. **Track dependencies.** A parent decision gates its children; resolving it
   may collapse or open downstream branches.
7. **Do not re-litigate.** Once a branch is settled, do not question it again
   unless a later answer contradicts it.

## The Loop

Repeat until the tree is fully resolved:

1. Pick the highest-uncertainty unresolved branch — the one whose answer most
   loads the rest of the plan. Avoid "tell me more"; ask something narrow
   whose wrong choice would bite later.
2. If the answer is a fact in the codebase, look it up, state the finding, and
   ask only for confirmation that it is load-bearing.
3. Otherwise, frame the decision as a single question to the user:
   - One question, scoped to this branch.
   - Where structured options are available, offer them: your recommended first
     (`(Recommended)`), then genuine alternatives (not cosmetic variations).
     Allow selecting several only when the options can genuinely coexist.
   - Where the answer is likely free-form, ask an open question instead.
4. Record the user's choice as the resolved value for that branch.
5. Note any new branches the answer opens, or branches it makes moot.

## Stop Condition

Stop when **every branch is resolved** — 100% alignment, nothing left
implicit. Do not stop early because it "feels done"; if an unresolved branch
remains, ask about it. If the user says "ship it" or "good enough," respect
that and stop, but name the branches left unresolved.

When done, emit a consolidated summary in the conversation:

```
Shared understanding reached. Locked decisions:
- [branch] → [choice] (rationale)
- ...
Unresolved / deferred: [list, or "none"]
```

Do not begin implementation unless explicitly asked — grilling is the job.

## When NOT to Use

- The plan is already locked and you just want execution.
- The task is a single reversible step with a fully constrained decision
  space — grilling adds overhead with no value.
- There is no downstream artifact. If the sharpened understanding won't feed a
  spec, PRD, or implementation, stateless grilling is discarded at the next
  session boundary; consider capturing it instead.
