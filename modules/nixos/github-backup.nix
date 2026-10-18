# Mirror this host's GitHub repos onto the backup disk with ghorg.
#
# Local-only by design: GitHub already holds the offsite copy of everything, so
# the dataset sets offsite = false and the driver's scoped local check — which
# stands in for the offsite verification — still marks the mirror verified.
# ghorg refreshes the bare mirrors in the dataset's preBackup step (it clones on
# the first run and `git remote update`s thereafter); the driver then
# rclone-copies /var/lib/github-mirrors into <mount>/GitHub/current.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.githubBackup;

  # ghorg reads its config from $XDG_CONFIG_HOME/ghorg/conf.yaml; pin it at an
  # empty store dir so a stray root conf can never redirect a backup run.
  emptyConfig = pkgs.runCommand "ghorg-empty-config" { } "mkdir -p $out";

  # The driver's preBackup hook runs as root with only the driver's PATH, so this
  # exports everything ghorg/git need. GIT_CONFIG_GLOBAL pins packing so the
  # mirror stays a handful of files per repo (see the checked-in gitconfig); the
  # token is passed as a file path, never inlined — this script is world-readable
  # in the Nix store.
  mirror = pkgs.writeShellScript "github-mirror-env" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.ghorg
        pkgs.git
        pkgs.git-lfs
        pkgs.coreutils
        pkgs.bash
      ]
    }
    export GIT_CONFIG_GLOBAL=${../features/backup/gitconfig}
    export XDG_CONFIG_HOME=${emptyConfig}
    export HOME=/root
    export GHORG_GITHUB_TOKEN=${lib.escapeShellArg cfg.tokenFile}
    export GHORG_ABSOLUTE_PATH_TO_CLONE_TO=/var/lib/github-mirrors
    export GHORG_CLONE_TYPE=user
    export GHORG_SCM_TYPE=github
    export GHORG_FETCH_GIT_LFS=true
    export GHORG_PROBE_REPO=${lib.escapeShellArg cfg.probeRepo}
    exec ${../features/backup/github-mirror.sh} ${lib.escapeShellArg config.dotfiles.githubUser}
  '';
in
{
  # Gate on the host's own knob only: reading the parent option
  # `dotfiles.backup.enable` here would recurse (this module defines a child of
  # it). backup-datasets.nix already asserts that any dataset needs the disk.
  config = lib.mkIf cfg.enable {
    dotfiles.backup.datasets.GitHub = {
      # ghorg writes <target>/<owner>_backup/<repo>/; the dataset source is the
      # parent, so the whole tree is mirrored.
      source = "/var/lib/github-mirrors";
      offsite = false;
      schedule = cfg.schedule;
      timeout = cfg.timeout;
      preBackup = "${mirror}";
    };
  };
}
