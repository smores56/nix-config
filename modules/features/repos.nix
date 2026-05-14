{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  grm = inputs.git-repo-manager.packages.${pkgs.stdenv.hostPlatform.system}.git-repo-manager;
  configPath = "$HOME/.config/grm/repos.toml";
  repoRoot = "$HOME/code";
  prefix = "${cfg.branchPrefix}/";
  grmNixConfigRepoEntry = ''
    [[trees]]
    root = "${config.home.homeDirectory}/code/smores56"

    [[trees.repos]]
    name = "nix-config"
    worktree_setup = true

    [[trees.repos.remotes]]
    name = "origin"
    url = "git@github.com:smores56/nix-config.git"
    type = "ssh"
  '';
  grmDefaultConfig = ''
    # Machine-local GRM repo inventory.
    # Edit this file directly to add or remove cloned repos.
    # Nix only seeds the dotfiles repo entry below.
    # Keep worktree_setup = true so new syncs use GRM's worktree layout.

    ${grmNixConfigRepoEntry}
  '';
in
{
  home.packages = [ grm ];

  xdg.configFile."grm/repos.example.toml".text = grmDefaultConfig;

  home.activation.ensureGrmNixConfigRepo = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    grm_config="${config.home.homeDirectory}/.config/grm/repos.toml"
    mkdir -p "$(${pkgs.coreutils}/bin/dirname "$grm_config")"

    if [ ! -e "$grm_config" ]; then
      cat > "$grm_config" <<'EOF'
    ${grmDefaultConfig}
    EOF
    elif ! ${pkgs.gnugrep}/bin/grep -Eq 'github\.com[:/]smores56/nix-config(\.git)?' "$grm_config"; then
      cat >> "$grm_config" <<'EOF'

    # Required dotfiles repository.
    ${grmNixConfigRepoEntry}
    EOF
    fi
  '';

  programs.fish.shellAbbrs = {
    r = "find ${repoRoot} -maxdepth 3 -type d -name .git-main-working-tree | sed \"s|^${repoRoot}/||;s|/\\.git-main-working-tree$||\" | tv | read -l s; and c ${repoRoot}/$s";
    grc = "grm repos sync config --config ${configPath}";
    grf = "grm repos find config --config ${configPath}";
    gri = "grm-init-repos";
    grl = "grm repos find local ${repoRoot} --format toml";
    grs = "grm repos status --config ${configPath}";
    w = "grm wt status";
    wf = "grm wt fetch";
    wp = "grm wt pull --rebase --stash";
    wr = "grm wt rebase --pull --rebase --stash";
    wd = "grm wt delete";
    nw = "grm-new-worktree";
    nb = "grm-new-worktree";
  };

  programs.fish.functions.grm-init-repos = {
    description = "Create an editable GRM repo inventory if missing";
    body = ''
      set -l config ~/.config/grm/repos.toml
      if test -e $config
          echo "Already exists: $config"
          return 1
      end

      mkdir -p (dirname $config)
      cp ~/.config/grm/repos.example.toml $config
      echo $config
    '';
  };

  programs.fish.functions.grm-new-worktree = {
    description = "Create a GRM worktree with the configured branch prefix";
    body = ''
      set -l name $argv[1]
      if test -z "$name"
          echo "Usage: grm-new-worktree <branch-suffix>"
          return 1
      end

      set -l branch $name
      if not string match -q '${prefix}*' $branch
          set branch '${prefix}'$branch
      end

      grm wt add $branch --track origin/$branch
    '';
  };

  programs.fish.functions.grm-lazygit = {
    description = "Open LazyGit in the current Git worktree or a GRM worktree";
    body = ''
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1
          command lazygit $argv
          return $status
      end

      set -l dir $PWD
      while test "$dir" != /
          if test -d "$dir/.git-main-working-tree"
              set -l worktrees
              for child in (find "$dir" -mindepth 1 -maxdepth 1 -type d)
                  if test -e "$child/.git"
                      set -a worktrees "$child"
                  end
              end

              set -l worktree_count (count $worktrees)
              if test $worktree_count -eq 0
                  echo "No GRM worktrees found under $dir"
                  echo "Create one with: grm wt add main --track origin/main"
                  return 1
              end

              if test $worktree_count -eq 1
                  command lazygit --path "$worktrees[1]" $argv
                  return $status
              end

              if command -q tv
                  set -l names
                  for worktree in $worktrees
                      set -a names (basename "$worktree")
                  end

                  printf '%s\n' $names | tv | read -l selected
                  if test -z "$selected"
                      return 1
                  end

                  command lazygit --path "$dir/$selected" $argv
                  return $status
              end

              echo "Multiple GRM worktrees found under $dir"
              for worktree in $worktrees
                  echo "  "(basename "$worktree")
              end
              echo "Run from a worktree, or install tv to select one from the GRM root."
              return 1
          end

          set dir (dirname "$dir")
      end

      command lazygit $argv
    '';
  };
}
