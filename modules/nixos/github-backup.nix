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
  cfg = config.githubBackup;
  mirrorRoot = "/var/lib/github-mirrors";

  # ghorg reads its config from $XDG_CONFIG_HOME/ghorg/conf.yaml; pin it at an
  # empty store dir so a stray root conf can never redirect a backup run.
  emptyConfig = pkgs.runCommand "ghorg-empty-config" { } "mkdir -p $out";

  # The driver's preBackup hook runs as root with only the driver's PATH, so this
  # exports everything ghorg/git need. GIT_CONFIG_GLOBAL pins packing so the
  # mirror does not grow loose objects or get rewritten by auto-maintenance (see
  # the checked-in gitconfig); the token is passed as a file path, never
  # inlined — this script is world-readable in the Nix store.
  #
  # `env -i` scrubs inherited GHORG_* (GHORG_CONFIG, GHORG_DEBUG, GHORG_PRUNE,
  # GHORG_TOKEN_CMD, ...) and `cd /` avoids ghorg's ./ghorg.yaml lookup, so a
  # privileged manual run cannot be redirected by its environment or cwd.
  mirror = pkgs.writeShellScript "github-mirror-env" ''
    cd /
    exec ${pkgs.coreutils}/bin/env -i \
      PATH=${
        lib.escapeShellArg (
          lib.makeBinPath [
            pkgs.ghorg
            pkgs.git
            pkgs.git-lfs
            pkgs.coreutils
            pkgs.bash
          ]
        )
      } \
      HOME=/root \
      XDG_CONFIG_HOME=${emptyConfig} \
      GIT_CONFIG_GLOBAL=${../features/backup/gitconfig} \
      GHORG_GITHUB_TOKEN=${lib.escapeShellArg cfg.tokenFile} \
      GHORG_ABSOLUTE_PATH_TO_CLONE_TO=${mirrorRoot} \
      GHORG_CLONE_TYPE=user \
      GHORG_SCM_TYPE=github \
      GHORG_FETCH_GIT_LFS=true \
      GHORG_PROBE_REPO=${lib.escapeShellArg cfg.probeRepo} \
      ${../features/backup/github-mirror.sh} ${lib.escapeShellArg config.user.githubUser}
  '';
in
{
  options.githubBackup = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "mirroring this host's GitHub repos onto the backup disk";
        tokenFile = lib.mkOption {
          # str, not path: a path interpolated into a derivation is copied into
          # the Nix store, which would publish the token.
          type = lib.types.str;
          default = "/run/secrets/github-repo-pat";
          description = "Runtime file holding a GitHub token that can read every mirrored repo, read by ghorg; never placed in the Nix store. A classic `repo` token also grants write access to every repo the account can reach, so keep it root-only.";
        };
        probeRepo = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "A known-private repo name (required). The run fails unless that repo was refreshed in the current run, catching a token that lost `repo` scope: ghorg then lists only public repos, leaves the old private mirrors in place, and still exits 0.";
        };
        schedule = lib.mkOption {
          type = lib.types.str;
          default = "*-*-* 00:30:00";
          description = "systemd OnCalendar for the mirror timer. A local-only dataset takes its own lock, so it neither waits on nor starves the Proton datasets.";
        };
        timeout = lib.mkOption {
          type = lib.types.str;
          default = "6h";
          description = "systemd TimeSpan cap on a run; generous for a cold clone of every repo.";
        };
        fullCheckSchedule = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "Sun *-*-* 10:00:00";
          description = "systemd OnCalendar for a periodic whole-tree verification (null disables). The nightly check only walks the files copied that run, so unchanged packs would otherwise never be re-read.";
        };
      };
    };
    default = { };
    description = "Mirror this host's GitHub repos onto the backup disk via ghorg (local-only; GitHub is the offsite copy).";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.probeRepo != "";
        message = "githubBackup.probeRepo must name a known-private repo; it is the only guard against a token that silently loses `repo` scope.";
      }
    ];

    # ghorg only sets 0700 when it creates the target itself, and git creates
    # the repo dirs 0755; enforce the barrier that keeps private repo contents
    # out of other users' reach.
    systemd.tmpfiles.rules = [
      "d ${mirrorRoot} 0700 root root -"
    ];

    backup.datasets.GitHub = {
      # ghorg writes <target>/<owner>_backup/<repo>/; the dataset source is the
      # parent, so the whole tree is mirrored.
      source = mirrorRoot;
      offsite = false;
      inherit (cfg) fullCheckSchedule schedule timeout;
      preBackup = "${mirror}";
    };
  };
}
