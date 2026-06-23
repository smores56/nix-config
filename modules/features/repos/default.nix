{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  # Shared shell prelude that resolves whether the repo at $PWD is a work-org
  # repo (origin GitHub org in workGithubOrgs) and exports the resulting
  # identity. This is the per-repo replacement for the old per-host branch
  # prefix; it mirrors the org signal used by git-github-ssh.
  resolvePrelude = ''
    WORK_ORGS=(${lib.escapeShellArgs cfg.workGithubOrgs})
    PERSONAL_PREFIX=${lib.escapeShellArg cfg.branchPrefix}
    WORK_PREFIX=${lib.escapeShellArg (toString (cfg.workBranchPrefix or ""))}
    TICKET_PREFIX=${lib.escapeShellArg (toString (cfg.ticketPrefix or ""))}

    origin_org() {
      local url path
      url=$(git remote get-url origin 2>/dev/null) || url=""
      case "$url" in
        git@github.com:*) path=''${url#git@github.com:} ;;
        ssh://git@github.com/*) path=''${url#ssh://git@github.com/} ;;
        https://github.com/*) path=''${url#https://github.com/} ;;
        http://github.com/*) path=''${url#http://github.com/} ;;
        *) path="" ;;
      esac
      printf '%s' "''${path%%/*}"
    }

    is_work_repo() {
      local org w
      org=$(origin_org)
      [ -n "$org" ] || return 1
      for w in ''${WORK_ORGS[@]+"''${WORK_ORGS[@]}"}; do
        [ "$org" = "$w" ] && return 0
      done
      return 1
    }

    work_branch_prefix() {
      if [ -n "$WORK_PREFIX" ]; then printf '%s' "$WORK_PREFIX"; else printf '%s' "$PERSONAL_PREFIX"; fi
    }
  '';

  # Print the branch prefix for the current repo, ready for a human to append
  # the rest of the branch name. Work: `<workPrefix>/<ticketPrefix>-`
  # (e.g. `sam.mohr/7AI-`). Personal: `<personalPrefix>/` (e.g. `smores/`).
  gitBranchPrefix = pkgs.writeShellApplication {
    name = "git-branch-prefix";
    runtimeInputs = [ pkgs.git ];
    text = ''
      ${resolvePrelude}

      if is_work_repo; then
        if [ -n "$TICKET_PREFIX" ]; then
          printf '%s/%s-' "$(work_branch_prefix)" "$TICKET_PREFIX"
        else
          printf '%s/' "$(work_branch_prefix)"
        fi
      else
        printf '%s/' "$PERSONAL_PREFIX"
      fi
    '';
  };

  # Resolve a full branch name from an agent-supplied slug. For work repos a
  # Linear ticket id is required: taken from --ticket, extracted from --task,
  # or created via the Linear CLI. Personal repos get `<personalPrefix>/<slug>`.
  # --dry-run is optional test-only behavior and is not used by spawn tools.
  #
  #   agent-branch-name --slug <slug> [--task <text>] [--ticket <id>] [--dry-run]
  agentBranchName = pkgs.writeShellApplication {
    name = "agent-branch-name";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      ${resolvePrelude}

      slug=""
      task=""
      ticket=""
      dry_run=false
      while [ $# -gt 0 ]; do
        case "$1" in
          --slug) slug=$2; shift 2 ;;
          --task) task=$2; shift 2 ;;
          --ticket) ticket=$2; shift 2 ;;
          --dry-run) dry_run=true; shift ;;
          *) printf 'agent-branch-name: unknown arg: %s\n' "$1" >&2; exit 2 ;;
        esac
      done

      slugify() {
        printf '%s' "$1" \
          | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
          | cut -c1-50 \
          | sed -E 's/-+$//'
      }

      if [ -z "$slug" ]; then
        [ -n "$task" ] || { printf 'agent-branch-name: --slug or --task required\n' >&2; exit 2; }
        # Strip any ticket reference from the task before slugifying so it is
        # not duplicated alongside the resolved ticket id.
        clean=$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')
        if [ -n "$TICKET_PREFIX" ]; then
          tp_lower=$(printf '%s' "$TICKET_PREFIX" | tr '[:upper:]' '[:lower:]')
          clean=$(printf '%s' "$clean" | sed -E "s/$tp_lower-[0-9]+//g")
        fi
        slug=$(slugify "$clean")
      fi
      [ -n "$slug" ] || { printf 'agent-branch-name: empty slug\n' >&2; exit 2; }

      if ! is_work_repo; then
        printf '%s/%s\n' "$PERSONAL_PREFIX" "$slug"
        exit 0
      fi

      # Work repo: resolve a ticket id.
      if [ -z "$ticket" ] && [ -n "$task" ] && [ -n "$TICKET_PREFIX" ]; then
        ticket=$(printf '%s' "$task" | grep -oiE "$TICKET_PREFIX-[0-9]+" | head -1 || true)
      fi

      if [ -z "$ticket" ] && [ -n "$TICKET_PREFIX" ]; then
        if $dry_run; then
          ticket="$TICKET_PREFIX-DRYRUN"
        else
          title=$task
          [ -n "$title" ] || title=$slug
          created=$(linear issue create -t "$title" --team "$TICKET_PREFIX" --assignee self --start --no-interactive 2>&1) || {
            printf 'agent-branch-name: linear issue create failed:\n%s\n' "$created" >&2
            exit 1
          }
          ticket=$(printf '%s' "$created" | grep -oiE "$TICKET_PREFIX-[0-9]+" | head -1 || true)
          [ -n "$ticket" ] || {
            printf 'agent-branch-name: could not parse ticket id from linear output:\n%s\n' "$created" >&2
            exit 1
          }
        fi
      fi

      if [ -n "$ticket" ]; then
        printf '%s/%s-%s\n' "$(work_branch_prefix)" "$ticket" "$slug"
      else
        printf '%s/%s\n' "$(work_branch_prefix)" "$slug"
      fi
    '';
  };
in
{
  home.packages = with pkgs; [
    ghq
    worktrunk
    gitBranchPrefix
    agentBranchName
  ];

  programs.git.settings.ghq.root = cfg.codeRoot;

  home.file = {
    ".config/television/cable/repos.toml".source = ./tv-repos.toml;
    ".config/television/cable/worktrees.toml".source = ./tv-worktrees.toml;
  };

  home.activation.seedWorktrunkConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="$HOME/.config/worktrunk/config.toml"
    source=${../worktrunk/config.toml}

    run mkdir -p "$HOME/.config/worktrunk"
    if [ -L "$target" ]; then
      run rm "$target"
    fi
    if [ ! -e "$target" ]; then
      run install -m 0644 "$source" "$target"
    fi
  '';

  programs.fish = {
    # Resolve the branch prefix from the current repo at expansion time so `wa`
    # follows the per-repo (origin org) identity rather than a per-host prefix.
    functions.__wa_expand = ''
      set -l prefix (git-branch-prefix 2>/dev/null)
      echo "wt switch --create --no-hooks $prefix%"
    '';

    interactiveShellInit = ''
      wt config shell init fish | source
      abbr -a wa --set-cursor --function __wa_expand
    '';

    shellAbbrs = {
      r = "tv repos | read -l s; and c $s";
      w = "tv worktrees | read -l s; and c $s";
      wc = "wt switch --create --no-hooks";
      wm = "wt merge";
      wx = "wt remove";
      wl = "wt list";
    };
  };
}
