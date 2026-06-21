{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  personalPrefix = cfg.branchPrefix;
  workPrefix = cfg.workBranchPrefix;
  hasWork = cfg.workGithubOrgs != [ ] && workPrefix != null;
  hasTicket = hasWork && cfg.ticketPrefix != null;
  workOrgList = lib.concatStringsSep ", " cfg.workGithubOrgs;
  workBranchExample =
    if hasTicket then
      "${workPrefix}/${cfg.ticketPrefix}-12345-fix-auth-flow"
    else
      "${workPrefix}/fix-auth-flow";

  branchWorkflowLines = [
    "- Branch prefix is per-repo, resolved from the `origin` GitHub org — run `git-branch-prefix` in the repo to get it; never hardcode the prefix"
    "- Personal repos: `${personalPrefix}/<kebab-slug>` (e.g. `${personalPrefix}/fix-auth-flow`)"
  ]
  ++ lib.optionals hasWork [
    "- Work-org repos (${workOrgList}): `${workBranchExample}`"
  ]
  ++ lib.optionals hasTicket [
    "- Every work-org change references a ${cfg.ticketPrefix} Linear ticket"
    "- To create a ticket: `linear issue create -t \"Title\" --team ${cfg.ticketPrefix} --assignee self --start`"
    "- To list your tickets: `linear issue mine`; to view one: `linear issue view ${cfg.ticketPrefix}-<number>`"
  ]
  ++ [
    "- Resolve a full branch for a task with `agent-branch-name --slug <kebab-slug> --task \"<description>\"` (auto-creates a Linear ticket for work-org repos when none is supplied)"
    "- Create worktrees with `wt switch --create $(git-branch-prefix)<rest-of-branch>`"
    "- **CRITICAL**: `wt switch` cannot cd in non-interactive shells. Always use `wt switch --format json` to get the worktree path as JSON. After switching, you MUST pass `cwd: \"<worktree_path>\"` to ALL subsequent bash commands — never rely on `cd` within bash scripts"
    "- Do NOT use `git clone`, `git worktree add`, `git checkout -b`, or Claude's built-in EnterWorktree"
  ];

  branchWorkflow = lib.concatStringsSep "\n" branchWorkflowLines;
  workGithubOrgHint = lib.optionalString (cfg.workGithubOrgs != [ ]) ''
    - Work GitHub orgs (${lib.concatStringsSep ", " cfg.workGithubOrgs}) use canonical `github.com` remotes and paths
  '';

  aiHints = ''
    # Code Style
    - Strongly prefer functional programming: pure functions, immutability, composition over inheritance
    - Single-purpose functions — no flag parameters, no multi-mode behavior
    - Prefer pattern matching and algebraic data types where available
    - Prefer early returns and guard clauses over nested conditionals
    - Prefer structured types over untyped dictionaries/maps/objects

    # Comments
    - No comments on self-explanatory code
    - Comments explain WHY, never WHAT
    - No multi-line comment blocks or verbose docstrings

    # Data
    - Transform data at point of use — keep it in its richest form until the consumer needs a different shape
    - Avoid eager conversion (loses information prematurely) and lazy conversion (adds redundant intermediates)

    # Error Handling
    - Errors must be explicit — never silently swallow or fall back
    - Prefer Result/Option/Either types and typed error variants over exceptions or string messages
    - Error messages must include enough context to debug without a stack trace

    # Testing
    - Add tests when the change warrants it
    - Prefer real dependencies over mocks
    - Match test scope to the change being made

    # Git Workflow
    - ALL repos live under `${cfg.codeRoot}/` and are managed by `ghq` (layout: `${cfg.codeRoot}/<host>/<owner>/<repo>`)
    - Clone repos: `ghq get <owner/repo-or-url>`. Never `git clone` directly
    ${workGithubOrgHint}
    - ALL worktrees live under each repo's `.worktrees/` directory via `worktrunk` (`wt`)
    - Worktree of branch `<prefix>/X` lives at `.worktrees/X` inside the canonical checkout; everything up to and including the last `/` is stripped from the directory name
    - Always push immediately after committing — never leave local-only commits
    - Do not add `Co-Authored-By` trailers to commit messages (no AI attribution)
    ${branchWorkflow}
    - For personal repos: do all work in a worktree, commit and push after each meaningful change, merge back to main when all work is done, then clean up the worktree, local branch, and remote branch
    # Commits and PRs
    - Follow Conventional Commits: <https://www.conventionalcommits.org/en/v1.0.0/>
    - Types: feat, fix, refactor, chore, docs, test, perf, ci
    ${
      if hasTicket then
        "- Work-org repos: scope is the Linear ticket `type(${cfg.ticketPrefix}-<number>): description` (e.g. `fix(${cfg.ticketPrefix}-123): resolve token refresh`); other repos: `type(scope): description`"
      else
        "- Scope is the affected module or area: `type(scope): description`"
    }
    - Applies to both commit messages and PR titles

    # Communication
    - Non-interactive CLI commands only (flags over interactive prompts)

    # Caveman Mode (lite)
    - No filler (just/really/basically), pleasantries (sure/certainly), or hedging
    - Keep articles + full sentences. Short synonyms preferred (fix not "implement a solution for"). Technical terms exact
    - Pattern: `[thing] [action] [reason]. [next step].` — no preambles, postscripts, or tool-call narration
    - No decorative tables/emoji. Long raw error-log dumps only if asked; else quote shortest decisive line. Standard well-known acronyms (DB/API/HTTP) OK; never invent new ones
    - Code blocks, CLI commands, API names, error strings: verbatim. Code/commits/PRs: write normal
    - Preserve user's dominant language — compress style, not language. Never name or announce the style ("caveman mode on", third-person tags)
    - Auto-clarity: revert to normal for security warnings, irreversible action confirmations, multi-step sequences where compression risks misread, or when user asks. Resume after clear part done
  '';
in
{
  config = {
    home = {
      file = {
        ".claude/CLAUDE.md".text = aiHints;
      };
    };

    dotfiles.aiHints = aiHints;
  };
}
