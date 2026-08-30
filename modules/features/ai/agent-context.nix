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
  workOrgList = lib.concatStringsSep ", " work.githubOrgs;
  ticket = work.ticketPrefix;

  workflowLines = [
    "- Repos live under `${cfg.codeRoot}/<host>/<owner>/<repo>`; clone with `repos get <owner/repo-or-url>` — never `git clone`, `git worktree add`, `git checkout -b`, or Claude's EnterWorktree"
    "- Work orgs (${workOrgList}) use canonical `github.com` remotes and paths"
    "- Worktrees live under each repo's `.worktrees/` via `worktrees new`; it prints JSON — use its `path` as cwd, never `cd`"
    "- Start task worktrees with `worktrees new --slug <kebab-slug> --task \"<description>\"` (creates branch, worktree, and any Linear ticket)"
    "- Branches: personal `${personalPrefix}/<kebab-slug>`; work-org `${workPrefix}/${ticket}-<number>-<kebab-slug>`; every work-org change references a ${ticket} ticket"
    "- Create tickets with `linear issue create -t \"Title\" --team ${ticket} --assignee self --state \"In Progress\"` — avoid `--start` (creates a stray branch in the current worktree)"
    "- Feature work follows the `sdlc` skill — Linear is the single source of truth for design, plan, and task state; never write repo design docs. Design = feature ticket description; plan = child-ticket DAG (`blocks` relations); approval = `design-approved`/`plan-approved` labels"
    "- Run `research` before any non-trivial design; run `review` before merging non-trivial changes"
    "- Before a non-trivial decision stands, spawn a fresh read-only subagent to argue against it"
    "- Conventional Commits (feat, fix, refactor, chore, docs, test, perf, ci); work-org scope is the ticket — `fix(${ticket}-123): description` — otherwise `type(scope): description`; applies to commits and PR titles"
    "- Push immediately after committing; no `Co-Authored-By` trailers"
    "- Personal repos: worktree → commit and push per change → `review` → merge to main → clean up worktree and branches"
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
