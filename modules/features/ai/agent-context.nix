{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg.work) flatRepos toolShell;

  # Generated from the options so no employer name lives here.
  workHostLines = lib.optionals (cfg.workHost && flatRepos != null) (
    [
      "- This is a work host: work checkouts live flat in `${flatRepos.dir}`${
        lib.optionalString (flatRepos.envVar != null) " (`\$${flatRepos.envVar}`)"
      }, and `${cfg.codeRoot}/github.com/<org>` links there for ${
        lib.concatMapStringsSep ", " (org: "`${org}`") flatRepos.orgs
      }, so repo and worktree paths may print under `${flatRepos.dir}`; clone with `repos get` as usual"
    ]
    ++
      lib.optional (toolShell != null)
        "- The work tooling's shell functions and aliases exist only in interactive ${toolShell} (its rc files): run them as `${toolShell} -ic '<function> …'`, and chain whatever needs the env a function exports into the same call (`${toolShell} -ic '<function> && <command>'`)"
  );

  workflowLines = [
    "- Start from the problem, not a solution — state what's wrong or needed; a suspected approach is context, not the goal"
    "- First move on any request: classify aloud — quick fix, investigation, or feature — and act. Features run the `sdlc` skill (research → brainstorm → [grill] → plan → build → review & fix), except in `pr`-flow repos (below); quick fixes skip the funnel; investigations run `research` and report"
    "- Resuming: `sdlc list` shows in-flight features; pick one, then `sdlc bootstrap <feature>` and continue from the state repo — never from conversation memory"
    "- Repos live under `${cfg.codeRoot}/github.com/<owner>/<repo>`; clone with `repos get <owner/repo>` — never `git clone`, `git worktree add`, `git checkout -b`, or Claude's EnterWorktree"
    "- Worktrees live under each repo's `.worktrees/` via `worktrees new`; it prints JSON — use its `path` as cwd, never `cd`"
    "- Start task worktrees with `worktrees new --slug <kebab-slug> --task \"<description>\"` (creates branch + worktree); pass `--ticket <KEY>` whenever the work has a ticket (repos that don't name branches by ticket ignore it) and `--type <fix|feat|…>` when it asks for one"
    "- Branches come from `worktrees new`, which renders the repo's template (`git config smores.branchTemplate`); never hand-build a branch name, even where an installed team skill shows `git checkout -b`"
    "- Run `research` before any non-trivial design; run `review` before merging non-trivial changes"
    "- Behavior-changing work in testable code starts red: run the `test-driven-development` skill (failing test → minimal fix → refactor). Config or verification-only changes skip the loop — verify with the repo's checks instead"
    "- Before a non-trivial decision stands, spawn a fresh read-only subagent to argue against it"
    "- Commit messages and PR titles: Conventional Commits (feat, fix, refactor, chore, docs, test, perf, ci) with `type(scope): description` in `direct`-flow repos; elsewhere follow the repo's own convention (contributing docs, installed team skills, recent merged PRs)"
    "- Push immediately after committing; no `Co-Authored-By` trailers"
    "- How changes land follows `git config smores.flow` in the repo:"
    "  - `direct` (personal repos): worktree → commit and push per change → `review` → merge to main → clean up with `worktrees prune`"
    "  - `pr` (work repos): worktree → commit and push per change → `review` → open a PR with `gh pr create`; never merge to main yourself. Run sdlc phases in the conversation without `sdlc` state commands — its state repo is personal and must not hold work designs"
    "  - unset (third-party checkouts): follow the repo's own contribution rules"
  ]
  ++ workHostLines;

  aiHints = ''
    # Workflow
    ${lib.concatStringsSep "\n" workflowLines}

    # Style
    - Prefer functional style: pure functions, immutability, composition over inheritance; single-purpose functions; structured types over untyped maps
    - Comments match surrounding density; explain WHY, never WHAT
    - No filler, pleasantries, or hedging; `[thing] [action] [reason]. [next step].` pattern; code blocks, CLI commands, and error strings verbatim
    - Compress style, not language; always English; auto-clarity for security warnings, irreversible actions, or steps where compression risks misread
  '';
in
{
  config = {
    home.file = {
      ".claude/CLAUDE.md" = {
        force = true;
        text = aiHints;
      };
      ".codex/AGENTS.md" = {
        force = true;
        text = aiHints;
      };
    };

    dotfiles.aiHints = aiHints;
  };
}
