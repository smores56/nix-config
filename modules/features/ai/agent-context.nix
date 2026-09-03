{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  personalPrefix = cfg.branchPrefix;

  workflowLines = [
    "- Start from the problem, not a solution — state what's wrong or needed; a suspected approach is context, not the goal"
    "- First move on any request: classify aloud — quick fix, investigation, or feature — and act. Features run the `sdlc` skill (research → brainstorm → [grill] → plan → build → review & fix); quick fixes skip the funnel; investigations run `research` and report"
    "- Resuming: `sdlc list` shows in-flight features; pick one, then `sdlc bootstrap <feature>` and continue from the state repo — never from conversation memory"
    "- Repos live under `${cfg.codeRoot}/github.com/<owner>/<repo>`; clone with `repos get <owner/repo>` — never `git clone`, `git worktree add`, `git checkout -b`, or Claude's EnterWorktree"
    "- Worktrees live under each repo's `.worktrees/` via `worktrees new`; it prints JSON — use its `path` as cwd, never `cd`"
    "- Start task worktrees with `worktrees new --slug <kebab-slug> --task \"<description>\"` (creates branch + worktree)"
    "- Branches: `${personalPrefix}/<kebab-slug>`"
    "- Run `research` before any non-trivial design; run `review` before merging non-trivial changes"
    "- Behavior-changing work in testable code starts red: run the `test-driven-development` skill (failing test → minimal fix → refactor). Config or verification-only changes skip the loop — verify with the repo's checks instead"
    "- Before a non-trivial decision stands, spawn a fresh read-only subagent to argue against it"
    "- Conventional Commits (feat, fix, refactor, chore, docs, test, perf, ci) with `type(scope): description`; applies to commits and PR titles"
    "- Push immediately after committing; no `Co-Authored-By` trailers"
    "- Personal flow: worktree → commit and push per change → `review` → merge to main → clean up with `worktrees prune`"
  ];

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
