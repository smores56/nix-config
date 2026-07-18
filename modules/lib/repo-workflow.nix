{
  config,
  lib,
  pkgs,
}:
let
  cfg = config.dotfiles;

  workflowPrelude = ''
    WORK_ORGS=(${lib.escapeShellArgs cfg.work.githubOrgs})
    PERSONAL_PREFIX=${lib.escapeShellArg cfg.branchPrefix}
    WORK_PREFIX=${lib.escapeShellArg (toString (cfg.work.branchPrefix or ""))}
    TICKET_PREFIX=${lib.escapeShellArg (toString (cfg.work.ticketPrefix or ""))}

    json_string() {
      printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'
    }

    slugify() {
      printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-50 \
        | sed -E 's/-+$//'
    }

    origin_parts() {
      local url path host owner repo
      url=$(git remote get-url origin 2>/dev/null) || return 1
      case "$url" in
        git@*:*)
          host=''${url#git@}
          host=''${host%%:*}
          path=''${url#*:}
          ;;
        ssh://git@*/*)
          host=''${url#ssh://git@}
          host=''${host%%/*}
          path=''${url#ssh://git@*/}
          ;;
        https://*/*/*|http://*/*/*)
          path=''${url#*://}
          host=''${path%%/*}
          path=''${path#*/}
          ;;
        *) return 1 ;;
      esac
      path=''${path%.git}
      owner=''${path%%/*}
      repo=''${path#*/}
      repo=''${repo%%/*}
      [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
      printf '%s\t%s\t%s\n' "$host" "$owner" "$repo"
    }

    is_work_owner() {
      local owner=$1 w
      for w in ''${WORK_ORGS[@]+"''${WORK_ORGS[@]}"}; do
        [ "$owner" = "$w" ] && return 0
      done
      return 1
    }

    work_branch_prefix() {
      if [ -n "$WORK_PREFIX" ]; then printf '%s' "$WORK_PREFIX"; else printf '%s' "$PERSONAL_PREFIX"; fi
    }
  '';

  repos = pkgs.writeShellApplication {
    name = "repos";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      pkgs.gnused
      pkgs.television
    ];
    text = ''
      CODE_ROOT=${lib.escapeShellArg cfg.codeRoot}

      list_repos() {
        [ -d "$CODE_ROOT" ] || exit 0
        find "$CODE_ROOT" -mindepth 3 -maxdepth 3 -type d \
          | while IFS= read -r path; do
              if git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
                printf '%s\n' "$path"
              fi
            done \
          | sort
      }

      normalize_repo() {
        local input=$1 host owner repo path
        case "$input" in
          git@*:*)
            host=''${input#git@}
            host=''${host%%:*}
            path=''${input#*:}
            ;;
          ssh://git@*/*)
            host=''${input#ssh://git@}
            host=''${host%%/*}
            path=''${input#ssh://git@*/}
            ;;
          https://*/*/*|http://*/*/*)
            path=''${input#*://}
            host=''${path%%/*}
            path=''${path#*/}
            ;;
          */*/*)
            host=''${input%%/*}
            path=''${input#*/}
            ;;
          */*)
            host=github.com
            path=$input
            ;;
          *)
            printf 'repos get: expected owner/repo, host/owner/repo, or git URL: %s\n' "$input" >&2
            exit 2
            ;;
        esac
        path=''${path%.git}
        owner=''${path%%/*}
        repo=''${path#*/}
        repo=''${repo%%/*}
        [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || {
          printf 'repos get: could not parse repo: %s\n' "$input" >&2
          exit 2
        }
        printf '%s\t%s\t%s\n' "$host" "$owner" "$repo"
      }

      case "''${1-}" in
        ""|list|ls) list_repos ;;
        get)
          [ $# -eq 2 ] || { printf 'usage: repos get <repo-or-url>\n' >&2; exit 2; }
          parts=$(normalize_repo "$2")
          IFS=$'\t' read -r host owner repo <<< "$parts"
          dest="$CODE_ROOT/$host/$owner/$repo"
          url="git@$host:$owner/$repo.git"
          [ ! -e "$dest" ] || { printf 'repos get: destination exists: %s\n' "$dest" >&2; exit 1; }
          mkdir -p "$(dirname "$dest")"
          git clone "$url" "$dest"
          printf '%s\n' "$dest"
          ;;
        *)
          printf 'usage: repos [list|get <repo-or-url>]\n' >&2
          exit 2
          ;;
      esac
    '';
  };

  worktrees = pkgs.writeShellApplication {
    name = "worktrees";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.television
    ];
    text = ''
      ${workflowPrelude}

      list_worktrees() {
        git worktree list --porcelain | awk '
          /^worktree / { if (path && !bare) print path; path=substr($0, 10); bare=0; next }
          /^bare$/ { bare=1; next }
          END { if (path && !bare) print path }
        '
      }

      main_worktree() {
        list_worktrees | head -1
      }

      current_worktree() {
        git rev-parse --show-toplevel
      }

      default_ref() {
        local ref
        ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
        if [ -n "$ref" ]; then printf '%s\n' "$ref"; return 0; fi
        if git rev-parse --verify --quiet origin/main >/dev/null; then printf 'origin/main\n'; return 0; fi
        if git rev-parse --verify --quiet origin/master >/dev/null; then printf 'origin/master\n'; return 0; fi
        printf 'HEAD\n'
      }

      worktree_branch() {
        git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
      }

      clean_task() {
        local value=$1 lower_prefix
        value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
        if [ -n "$TICKET_PREFIX" ]; then
          lower_prefix=$(printf '%s' "$TICKET_PREFIX" | tr '[:upper:]' '[:lower:]')
          value=$(printf '%s' "$value" | sed -E "s/$lower_prefix-[0-9]+//g")
        fi
        printf '%s' "$value"
      }

      create_new() {
        local slug="" task="" ticket="" base="" dry_run=false created title parts host owner repo clean prefix branch name root path default
        while [ $# -gt 0 ]; do
          case "$1" in
            --slug) slug=$2; shift 2 ;;
            --task) task=$2; shift 2 ;;
            --ticket) ticket=$2; shift 2 ;;
            --base) base=$2; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) printf 'worktrees new: unknown arg: %s\n' "$1" >&2; exit 2 ;;
          esac
        done

        [ -n "$slug" ] || {
          [ -n "$task" ] || { printf 'worktrees new: --slug or --task required\n' >&2; exit 2; }
          clean=$(clean_task "$task")
          slug=$(slugify "$clean")
        }
        slug=$(slugify "$slug")
        [ -n "$slug" ] || { printf 'worktrees new: empty slug\n' >&2; exit 2; }

        parts=$(origin_parts) || { printf 'worktrees new: could not parse origin remote\n' >&2; exit 1; }
        IFS=$'\t' read -r host owner repo <<< "$parts"

        if is_work_owner "$owner"; then
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
                printf 'worktrees new: linear issue create failed:\n%s\n' "$created" >&2
                exit 1
              }
              ticket=$(printf '%s' "$created" | grep -oiE "$TICKET_PREFIX-[0-9]+" | head -1 || true)
              [ -n "$ticket" ] || {
                printf 'worktrees new: could not parse ticket id from linear output:\n%s\n' "$created" >&2
                exit 1
              }
            fi
          fi
          prefix=$(work_branch_prefix)
          if [ -n "$ticket" ]; then
            branch="$prefix/$ticket-$slug"
            name="$ticket-$slug"
          else
            branch="$prefix/$slug"
            name="$slug"
          fi
        else
          if [ -n "$ticket" ]; then
            printf 'worktrees new: --ticket is only valid for work repos\n' >&2
            exit 2
          fi
          branch="$PERSONAL_PREFIX/$slug"
          name="$slug"
        fi

        root=$(main_worktree)
        [ -n "$root" ] || { printf 'worktrees new: could not resolve main worktree\n' >&2; exit 1; }
        path="$root/.worktrees/$name"

        if $dry_run; then
          if [ -z "$base" ]; then
            default=$(default_ref)
            base=$default
          fi
          printf '{"branch":%s,"path":%s,"ticket":' "$(json_string "$branch")" "$(json_string "$path")"
          if [ -n "$ticket" ]; then json_string "$ticket"; else printf 'null'; fi
          printf ',"base":%s,"dry_run":true}\n' "$(json_string "$base")"
          exit 0
        fi

        if git show-ref --verify --quiet "refs/heads/$branch"; then
          printf 'worktrees new: branch already exists: %s\n' "$branch" >&2
          exit 1
        fi
        [ ! -e "$path" ] || { printf 'worktrees new: path already exists: %s\n' "$path" >&2; exit 1; }
        git fetch origin
        if [ -z "$base" ]; then
          default=$(default_ref)
          base=$default
        fi
        mkdir -p "$(dirname "$path")"
        git worktree add "$path" -b "$branch" "$base" >/dev/null
        printf '{"branch":%s,"path":%s,"ticket":' "$(json_string "$branch")" "$(json_string "$path")"
        if [ -n "$ticket" ]; then json_string "$ticket"; else printf 'null'; fi
        printf ',"base":%s}\n' "$(json_string "$base")"
      }

      ref_sha() {
        git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || true
      }

      integrated_reason() {
        local branch=$1 target=$2 branch_sha target_sha merge_base merged_tree target_tree diff
        branch_sha=$(ref_sha "$branch")
        target_sha=$(ref_sha "$target")
        [ -n "$branch_sha" ] && [ -n "$target_sha" ] || return 1
        if [ "$branch_sha" = "$target_sha" ]; then
          printf 'same-commit\n'
          return 0
        fi
        if git merge-base --is-ancestor "$branch" "$target"; then
          printf 'ancestor\n'
          return 0
        fi
        if merge_base=$(git merge-base "$target" "$branch" 2>/dev/null) && [ -n "$merge_base" ]; then
          diff=$(git diff --name-only "$merge_base..$branch" 2>/dev/null || true)
          if [ -z "$diff" ]; then
            printf 'no-added-changes\n'
            return 0
          fi
        fi
        merged_tree=$(git merge-tree --write-tree "$target" "$branch" 2>/dev/null) || return 1
        target_tree=$(git rev-parse "$target^{tree}") || return 1
        if [ "$merged_tree" = "$target_tree" ]; then
          printf 'content-integrated\n'
          return 0
        fi
        return 1
      }

      delete_flag_for() {
        case "$1" in
          ancestor|same-commit|no-added-changes) printf '%s\n' -d ;;
          *) printf '%s\n' -D ;;
        esac
      }

      duration_seconds() {
        local spec=$1
        case "$spec" in
          0s) printf '%s\n' 0 ;;
          *s) printf '%s\n' "''${spec%s}" ;;
          *m) printf '%s\n' $(( ''${spec%m} * 60 )) ;;
          *h) printf '%s\n' $(( ''${spec%h} * 3600 )) ;;
          *d) printf '%s\n' $(( ''${spec%d} * 86400 )) ;;
          *) printf 'worktrees prune: invalid --min-age: %s\n' "$spec" >&2; exit 2 ;;
        esac
      }

      worktree_age_seconds() {
        local path=$1 git_dir meta
        git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
        meta=$git_dir
        [ -f "$git_dir/commondir" ] && meta="$git_dir/$(cat "$git_dir/commondir" 2>/dev/null)"
        stat -c '%Y' "$meta" 2>/dev/null || stat -f '%m' "$meta" 2>/dev/null || return 1
      }

      branch_age_seconds() {
        local branch=$1 refname created_epoch
        refname="refs/heads/$branch"
        created_epoch=$(git reflog show --format='%ct' "$refname" 2>/dev/null | tail -1)
        [ -n "$created_epoch" ] || return 1
        printf '%s\n' "$created_epoch"
      }

      prune_worktrees() {
        local dry_run=false min_age=0s min_age_secs now current main target target_branch
        local path branch reason action delete_flag age created skip_reason
        while [ $# -gt 0 ]; do
          case "$1" in
            --dry-run) dry_run=true; shift ;;
            --min-age) min_age=$2; shift 2 ;;
            --min-age=*) min_age=''${1#--min-age=}; shift ;;
            *) printf 'worktrees prune: unknown arg: %s\n' "$1" >&2; exit 2 ;;
          esac
        done
        min_age_secs=$(duration_seconds "$min_age")
        now=$(date +%s)
        current=$(current_worktree)
        main=$(main_worktree)
        target=$(default_ref)
        target_branch=''${target#origin/}

        git fetch origin 2>/dev/null || true

        list_worktrees | while IFS= read -r path; do
          [ "$path" != "$main" ] || continue
          branch=$(worktree_branch "$path")
          [ -n "$branch" ] || continue
          [ "$branch" != "$target_branch" ] || continue
          reason=$(integrated_reason "$branch" "$target" || true)
          [ -n "$reason" ] || continue
          if [ "$min_age_secs" -gt 0 ]; then
            created=$(worktree_age_seconds "$path" 2>/dev/null) || continue
            age=$(( now - created ))
            if [ "$age" -lt "$min_age_secs" ]; then
              printf 'skip %s branch %s reason younger-than-%s\n' "$path" "$branch" "$min_age" >&2
              continue
            fi
          fi
          if $dry_run; then action=would-remove; else action=remove; fi
          printf '%s %s branch %s reason %s\n' "$action" "$path" "$branch" "$reason"
          if ! $dry_run; then
            if [ "$path" = "$current" ]; then skip_reason='current worktree'; else
              if ! git worktree remove "$path" 2>/dev/null; then
                skip_reason='removal blocked (dirty or locked)'
              else
                skip_reason=
              fi
            fi
            if [ -n "$skip_reason" ]; then
              printf 'skip %s branch %s reason %s\n' "$path" "$branch" "$skip_reason" >&2
            else
              delete_flag=$(delete_flag_for "$reason")
              git branch "$delete_flag" "$branch" 2>/dev/null || true
            fi
          fi
        done

        # Orphan branches: local branches with no worktree, not the default.
        local orphan_branches_with_worktree orphan_branch
        orphan_branches_with_worktree=$(list_worktrees | while IFS= read -r wt_path; do
          worktree_branch "$wt_path"
        done)
        for orphan_branch in $(git for-each-ref --format='%(refname:short)' refs/heads); do
          [ "$orphan_branch" != "$target_branch" ] || continue
          printf '%s\n' "$orphan_branches_with_worktree" | grep -qx "$orphan_branch" && continue
          reason=$(integrated_reason "$orphan_branch" "$target" || true)
          [ -n "$reason" ] || continue
          if [ "$min_age_secs" -gt 0 ]; then
            created=$(branch_age_seconds "$orphan_branch" 2>/dev/null) || continue
            age=$(( now - created ))
            if [ "$age" -lt "$min_age_secs" ]; then
              printf 'skip branch %s reason younger-than-%s\n' "$orphan_branch" "$min_age" >&2
              continue
            fi
          fi
          if $dry_run; then action=would-remove; else action=remove; fi
          printf '%s branch-only %s reason %s\n' "$action" "$orphan_branch" "$reason"
          if ! $dry_run; then
            delete_flag=$(delete_flag_for "$reason")
            git branch "$delete_flag" "$orphan_branch" 2>/dev/null || true
          fi
        done

        if ! $dry_run; then git worktree prune; fi
      }

      case "''${1-}" in
        ""|list|ls) list_worktrees ;;
        new|n) shift; create_new "$@" ;;
        prune|p) shift; prune_worktrees "$@" ;;
        *) printf 'usage: worktrees [list|new|prune]\n' >&2; exit 2 ;;
      esac
    '';
  };
in
{
  inherit repos worktrees;
}
