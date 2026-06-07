{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) branchPrefix;

  hasTicket = cfg.ticketPrefix != null;
  branchSlug =
    if hasTicket then "${cfg.ticketPrefix}-<ticket-number>-<kebab-slug>" else "<kebab-slug>";
  exampleSlug = if hasTicket then "${cfg.ticketPrefix}-12345-fix-auth-flow" else "fix-auth-flow";

  branchWorkflowLines = [
    "- Branch format: `${branchPrefix}/${branchSlug}`"
    "- Example: `${branchPrefix}/${exampleSlug}`"
  ]
  ++ lib.optionals hasTicket [
    "- Every change must reference a ${cfg.ticketPrefix} Linear ticket"
    "- To create a ticket: `linear issue create -t \"Title\" --team ${cfg.ticketPrefix} --assignee self --start`"
    "- To list your tickets: `linear issue mine`"
    "- To view a ticket: `linear issue view ${cfg.ticketPrefix}-<number>`"
  ]
  ++ [
    "- Create worktrees with `wt switch --create ${branchPrefix}/${branchSlug}`"
    "- **CRITICAL**: `wt switch` cannot cd in non-interactive shells. Always use `wt switch --format json` to get the worktree path as JSON. After switching, you MUST pass `cwd: \"<worktree_path>\"` to ALL subsequent bash commands — never rely on `cd` within bash scripts"
    "- Worktree directories live inside the canonical checkout at `.worktrees/${branchSlug}` (worktrunk strips the `${branchPrefix}/` prefix)"
    "- Switch between worktrees: `wt switch --format json <branch>` to get the path, then use `cwd:` in bash calls"
    "- To return to the canonical (non-worktree) checkout: `cd ${cfg.codeRoot}/github.com/<owner>/<repo>`"
    "- Do NOT use `git clone`, `git worktree add`, `git checkout -b`, or Claude's built-in EnterWorktree"
    "- List worktrees: `wt list`"
    "- Remove a worktree: `wt remove` — from inside it, or with explicit `<branch>`"
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
    - Find repos: `ghq list -p | grep <name>`
    - ALL worktrees live under each repo's `.worktrees/` directory via `worktrunk` (`wt`)
    - Worktree of branch `${branchPrefix}/X` lives at `.worktrees/X` inside the canonical checkout; the `${branchPrefix}/` prefix is stripped from the directory name
    - Use `lazygit` from any worktree; it reads `git worktree list` natively
    - Always push immediately after committing — never leave local-only commits
    - Do not add `Co-Authored-By` trailers to commit messages (no AI attribution)
    ${branchWorkflow}
    ${lib.optionalString (!hasTicket) ''
      - For personal projects: do all work in a worktree, commit and push after each meaningful change, merge back to main when all work is done, then clean up the worktree, local branch, and remote branch
    ''}
    # Commits and PRs
    - Follow Conventional Commits: <https://www.conventionalcommits.org/en/v1.0.0/>
    - Types: feat, fix, refactor, chore, docs, test, perf, ci
    ${
      if hasTicket then
        "- Scope is the Linear ticket: `type(${cfg.ticketPrefix}-<number>): description` (e.g. `fix(${cfg.ticketPrefix}-123): resolve token refresh`)"
      else
        "- Scope is the affected module or area: `type(scope): description`"
    }
    - Applies to both commit messages and PR titles

    # Communication
    - Be concise — no verbose explanations unless asked
    - Non-interactive CLI commands only (flags over interactive prompts)

    # Retry Discipline
    If a command returns unexpected or ambiguous output **more than twice**, stop and investigate the cause instead of blindly retrying. Changing nothing and re-running is never productive.

    # Caveman Mode
    - Drop articles, filler words (just/really/basically), pleasantries, hedging
    - Fragments OK. Short synonyms preferred. Technical terms exact
    - Code blocks unchanged. Errors quoted verbatim
    - Compress explanations. Expand only for security warnings or when user confused
    - One sentence = one action. No preambles, no postscripts, no progress narration

    # Pi CLI Commands
    - `pi` — run Pi coding agent
    - `pip` — `pi -p` (plan mode, no destructive tools)
    - `pic` — `pi -c` (compact mode)
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
