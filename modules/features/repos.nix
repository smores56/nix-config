{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;

  wt-cargo-link = pkgs.writeShellScriptBin "wt-cargo-link" ''
    set -euo pipefail
    wt="''${1:?usage: wt-cargo-link <worktree-path>}"
    [ -f "$wt/Cargo.toml" ] || exit 0
    main=$(git -C "$wt" worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,"");p=$0} /^branch /{print p; exit}')
    [ -z "$main" ] && exit 0
    [ "$main" = "$wt" ] && exit 0
    for profile in debug release; do
      src="$main/target/$profile"
      dst="$wt/target/$profile"
      mkdir -p "$src/deps" "$src/build" "$dst"
      for subdir in deps build; do
        [ -d "$dst/$subdir" ] && [ ! -L "$dst/$subdir" ] && rm -rf "$dst/$subdir"
        ln -sfn "$src/$subdir" "$dst/$subdir"
      done
    done
  '';

  wt-node-link = pkgs.writeShellScriptBin "wt-node-link" ''
    set -euo pipefail
    wt="''${1:?usage: wt-node-link <worktree-path>}"
    [ -f "$wt/package.json" ] || exit 0
    main=$(git -C "$wt" worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,"");p=$0} /^branch /{print p; exit}')
    [ -z "$main" ] && exit 0
    [ "$main" = "$wt" ] && exit 0
    [ -d "$main/node_modules" ] || exit 0
    [ -d "$wt/node_modules" ] && [ ! -L "$wt/node_modules" ] && rm -rf "$wt/node_modules"
    ln -sfn "$main/node_modules" "$wt/node_modules"
  '';

  repoRoot = "~/dev/repos";
  prefix = "${cfg.branchPrefix}/";
in
{
  home.packages = [
    pkgs.worktrunk
    wt-cargo-link
    wt-node-link
  ];

  xdg.configFile."worktrunk/config.toml".text = ''
    worktree-path = "{{ repo_path }}/{{ branch | sanitize }}"

    [post-start]
    cargo = "wt-cargo-link '{{ worktree_path }}'"
    node = "wt-node-link '{{ worktree_path }}'"
    mise = "mise trust '{{ worktree_path }}/mise.toml' 2>/dev/null || true"
  '';

  programs.fish = {
    interactiveShellInit = lib.mkAfter ''
      command -q wt; and wt config shell init fish | source
    '';

    shellAbbrs = {
      r = "find ${repoRoot} -name .git -maxdepth 3 | sed 's|${repoRoot}/||;s|/\\.git||' | tv -p 'gh repo view {}' --cache-preview | read -l s; and c ${repoRoot}/$s";
      w = "wt switch";
      nw = "wt switch -c ${prefix}";
      nb = "git checkout -b ${prefix}";
    };

    functions.repo-clone = {
      description = "Bare clone a repo for worktrunk";
      body = ''
        set -l url $argv[1]
        if test -z "$url"
            echo "Usage: repo-clone <url>"
            return 1
        end
        set -l path (string replace -r '^(https?://|ssh://[^/]*/|git@)' "" $url | string replace -r '^([^/]+):' '$1/' | string replace -r '\.git$' "")
        set -l parts (string split '/' $path)
        if test (count $parts) -ge 3
            set path (string join '/' $parts[2..])
        end
        set -l dest ${repoRoot}/$path
        if test -d $dest/.git
            echo "Already exists: $dest"
            return 1
        end
        mkdir -p $dest
        if not git clone --bare $url $dest/.git
            rm -rf $dest
            return 1
        end
        git -C $dest config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git -C $dest fetch origin
        echo $dest
      '';
    };
  };
}
