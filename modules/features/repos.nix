{
  config,
  inputs,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  grm = inputs.git-repo-manager.packages.${pkgs.stdenv.hostPlatform.system}.git-repo-manager;
  configPath = "$HOME/.config/grm/repos.toml";
  repoRoot = "$HOME/code";
  prefix = "${cfg.branchPrefix}/";
in
{
  home.packages = [ grm ];

  xdg.configFile."grm/repos.example.toml".text = ''
    [[trees]]
    root = "~/code/owner"

    [[trees.repos]]
    name = "repo"
    worktree_setup = true

    [[trees.repos.remotes]]
    name = "origin"
    url = "git@github.com:owner/repo.git"
    type = "ssh"
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
}
