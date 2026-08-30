{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  work = cfg.work;
  personalPrefix = cfg.branchPrefix;
  workPrefix = work.branchPrefix;
  hasWork = work.githubOrgs != [ ] && workPrefix != null;
  hasTicket = hasWork && work.ticketPrefix != null;
  workOrgList = lib.concatStringsSep ", " work.githubOrgs;
  workBranchExample =
    if hasTicket then
      "${workPrefix}/${work.ticketPrefix}-12345-fix-auth-flow"
    else
      "${workPrefix}/fix-auth-flow";

  branchWorkflowLines = [
    "- Start task worktrees with `worktrees new --slug <kebab-slug> --task \"<description>\"`; it creates the branch, worktree, and any required Linear ticket"
    "- Personal repos create branches like `${personalPrefix}/<kebab-slug>` (e.g. `${personalPrefix}/fix-auth-flow`)"
  ]
  ++ lib.optionals hasWork [
    "- Work-org repos (${workOrgList}): `${workBranchExample}`"
  ]
  ++ lib.optionals hasTicket [
    "- Every work-org change references a ${work.ticketPrefix} Linear ticket"
    "- To create a ticket: `linear issue create -t \"Title\" --team ${work.ticketPrefix} --assignee self --state \"In Progress\"` (avoid `--start`: it creates and switches to a `<github-user>/<lowercase-ticket>` git branch in the current worktree — use `worktrees new` for ticket+worktree together)"
  ]
  ++ [
    "- `worktrees new` prints JSON; use its `path` field as cwd for subsequent commands — never rely on `cd` within bash scripts"
    "- Do NOT use `git clone`, `git worktree add`, `git checkout -b`, or Claude's built-in EnterWorktree"
  ];

  branchWorkflow = lib.concatStringsSep "\n" branchWorkflowLines;
  workGithubOrgHint = lib.optionalString (work.githubOrgs != [ ]) ''
    - Work GitHub orgs (${lib.concatStringsSep ", " work.githubOrgs}) use canonical `github.com` remotes and paths
  '';

  sdlcHints = lib.optionalString hasTicket ''
    # SDLC (${work.ticketPrefix})
    - Feature work follows the `sdlc` skill — Linear is the single source of truth for design, plan, and task state. Load it before starting any feature or planned task; never write repo design docs
    - Design = feature ticket description; plan = child-ticket DAG (`blocks` relations); approval = `design-approved`/`plan-approved` labels
  '';

  aiHints = ''
    # Skills
    - `research` — evidence before designing; mandatory for non-trivial design, scaled down mid-work when context is missing
    - `design-brainstorm` + `grill-me` — large-feature design and decision stress-testing
    - `sdlc` — work feature workflow (Linear SSOT)
    - `test-driven-development` — implement; `review` — mandatory before merging non-trivial changes; `resolve-pr` — land a PR
    - Before a non-trivial decision stands, spawn a fresh read-only subagent to argue against it

    # Code Style
    - Strongly prefer functional programming: pure functions, immutability, composition over inheritance
    - Single-purpose functions — no flag parameters, no multi-mode behavior
    - Prefer pattern matching, algebraic data types, and guard clauses over nested conditionals
    - Prefer structured types over untyped dictionaries/maps/objects; transform data at point of use — no eager or lazy conversion
    - Match surrounding comment density; comments explain WHY, never WHAT

    # Error Handling
    - Errors are explicit — never silently swallowed or fallen back from
    - Prefer Result/Option/Either types and typed error variants over exceptions or string messages; include enough context to debug without a stack trace

    # Git Workflow
    - ALL repos live under `${cfg.codeRoot}/` (layout: `${cfg.codeRoot}/<host>/<owner>/<repo>`)
    - Clone repos with SSH using `repos get <owner/repo-or-url>`. Never `git clone` directly
    ${workGithubOrgHint}
    - Worktrees live under each repo's `.worktrees/` via `worktrees new`
    - Always push immediately after committing — never leave local-only commits
    - Always use the `gh` CLI for GitHub interaction
    - Non-interactive CLI commands only (flags over interactive prompts)
    - Do not add `Co-Authored-By` trailers to commit messages (no AI attribution)
    ${branchWorkflow}
    - For personal repos: do all work in a worktree, commit and push after each meaningful change, `review` non-trivial changes before merging back to main, then clean up the worktree, local branch, and remote branch

    # Commits and PRs
    - Follow Conventional Commits: <https://www.conventionalcommits.org/en/v1.0.0/>
    - Types: feat, fix, refactor, chore, docs, test, perf, ci
    ${
      if hasTicket then
        "- Work-org repos: scope is the Linear ticket `type(${work.ticketPrefix}-<number>): description` (e.g. `fix(${work.ticketPrefix}-123): resolve token refresh`); other repos: `type(scope): description`"
      else
        "- Scope is the affected module or area: `type(scope): description`"
    }
    - Applies to both commit messages and PR titles

    ${sdlcHints}

    # Memory
    - Durable preferences and decisions only — no secrets, tokens, transient debug, or facts obvious from tracked files. Prefer repo docs/config as source of truth.

    # Terseness
    - No filler (just/really/basically), pleasantries, or hedging; keep articles + full sentences and prefer short exact synonyms (fix, not "implement a solution for")
    - Pattern: `[thing] [action] [reason]. [next step].` — no preambles, postscripts, or tool-call narration
    - No decorative tables/emoji; quote the shortest decisive error line; standard acronyms (DB/API/HTTP) only
    - Code blocks, CLI commands, API names, error strings: verbatim. Code/commits/PRs: write normal
    - Preserve the user's dominant language — compress style, not language. Always speak in English
    - Auto-clarity: revert to normal for security warnings, irreversible-action confirmations, multi-step sequences where compression risks misread, or when the user asks
  '';
in
{
  config = {
    home.file = lib.optionalAttrs cfg.work.enable {
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
