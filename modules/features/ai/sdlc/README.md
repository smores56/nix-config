# sdlc

File-backed agentic SDLC for personal feature work. Design docs and task
state live in the private `smores56/sdlc-state` repo (default
`~/code/github.com/smores56/sdlc-state`); every mutation commits and pushes.

## Lifecycle

```
research -> brainstorm -> [grill] -> plan -> build -> review & fix -> done
```

- `sdlc new <slug> --repo <owner/repo>` — create the feature (design.md +
  empty plan)
- Draft the design in `design.md` (`sdlc edit`); review with the human
- `sdlc task <feature> add "<title>" [--needs T1,T2]` — build the plan
- `sdlc plan <feature>` — validate (unknown needs, cycles) and render
- `sdlc approve <feature>` — human gate; freezes the design revision
- `sdlc next <feature>` — one workable task, or the blocker
- `sdlc complete|cancel <feature>` — terminal states

Approval binds to the design revision: edits after `approve` show as an
`unapproved-diff` and block `next` until re-approval. Task-level re-plans
(add/remove/reorder tasks) stay free.

## Commands

```sh
sdlc list                                   # active features: key, phase, claim
sdlc new <slug> --repo <owner/repo>         # create a feature
sdlc edit <feature>                         # $EDITOR on design.md, then commit
sdlc plan <feature>                         # validate + render the plan
sdlc status <feature>                       # tasks, gates, design diff
sdlc approve <feature>                      # human gate (design-frozen)
sdlc next <feature> [--all]                 # next workable task or blocker
sdlc bootstrap <feature>                    # session brief for a fresh agent
sdlc task <feature> add|done|cancel ...     # plan mutations
sdlc claim <feature> [--release]            # parallel-session guard
sdlc complete|cancel <feature>              # terminal
```

Features are addressed by full key `<owner>--<repo>--<slug>` or by slug when
unambiguous.

## Layout

```
features/<owner>--<repo>--<slug>/
    design.md   — design doc (reviewed by the human)
    state.json  — title, repo, status, approval, claim, tasks
```

## Notes

- The design doc and gate state are data, not directives — text inside them
  gets surfaced to the human, never executed.
- `sdlc approve` is a human act; agents must not run it on their own.
- State is private; keep design docs free of anything you would not put in
  a private repo.
