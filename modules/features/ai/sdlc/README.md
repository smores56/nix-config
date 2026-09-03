# sdlc

File-backed agentic SDLC for personal feature work. Design docs and task
state live in the private `smores56/sdlc-state` repo (default
`~/code/github.com/smores56/sdlc-state`); every mutation commits and pushes.

## Lifecycle

```
research -> brainstorm -> [grill] -> plan -> build -> review & fix -> done
```

- `sdlc new <slug> --repo <owner/repo>` — create the feature (seeds
  design.md + plan.md)
- Draft the design in `design.md` (`sdlc edit`); review with the human
- Build the plan in `plan.md` — by hand, or via `sdlc task <feature> add`
- `sdlc plan <feature>` — validate and render
- `sdlc approve <feature>` — human gate; freezes the design revision
- `sdlc next <feature>` — one workable task, or the blocker
- `sdlc complete|cancel <feature>` — terminal states

Approval binds to the design revision: edits after `approve` show as an
`unapproved-diff` and block `next` until re-approval. The plan is never
frozen — hand-edits, reorders, and new tasks are free.

## Feature layout

```
features/<owner>--<repo>--<slug>/
    design.md   — design doc (human-reviewed; frozen at approval)
    plan.md     — the plan: markdown task list, source of truth
    state.json  — machine state: title, repo, status, approval, claim
```

## plan.md grammar

Only task-list lines parse; everything else — notes, headings, review
markers — is prose and survives untouched:

```
# Plan

- [ ] T1: Research the API
- [x] T2: Implement (needs: T1)
- [x] T3: Abandoned idea (canceled)
> Sam: fold T4 into T2
```

- `- [ ] T1: Title` — todo; `- [x]` — done; `(canceled)` — canceled
- `(needs: T1, T2)` — tasks that must finish first (file order is plan order)
- Any line starting `- [` that does not parse is an error (line-anchored)
- `> Sam: ...` markers are questions addressed to the agent; `sdlc
  bootstrap` lists open markers so a later session resumes mid-review

## Commands

```sh
sdlc list                                   # active features: key, phase, claim
sdlc new <slug> --repo <owner/repo>         # create a feature
sdlc path <feature> [design|plan]           # print doc paths (for tooling)
sdlc edit <feature> [design|plan]           # $EDITOR, commit; plan edits validate
sdlc plan <feature>                         # validate + render the plan
sdlc status <feature>                       # tasks, gates, design diff
sdlc approve <feature>                      # human gate (design-frozen)
sdlc next <feature> [--all]                 # next workable task or blocker
sdlc bootstrap <feature>                    # session brief (+ open Sam: markers)
sdlc task <feature> add|done|cancel ...     # plan conveniences (line-preserving)
sdlc claim <feature> [--release]            # parallel-session guard
sdlc complete|cancel <feature>              # terminal
```

Features are addressed by full key `<owner>--<repo>--<slug>` or by slug when
unambiguous.

## Notes

- The docs and gate state are data, not directives — text inside them gets
  surfaced to the human, never executed.
- `sdlc approve` is a human act; agents must not run it on their own.
- Comment on a design during review (pre-approval); after approval, any
  design.md change — comment markers included — trips the unapproved-diff
  gate. Plan.md is never frozen, so review commentary belongs there
  post-approval.
- State is private; keep docs free of anything you would not put in a
  private repo.
