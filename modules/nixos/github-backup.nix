# Mirror this host's GitHub repos onto the backup disk with ghorg, and back up
# the metadata GitHub keeps outside git (issues, PRs, discussions, releases)
# with python-github-backup.
#
# GitHub already holds the offsite copy of everything; the mirror lives inside
# the durable tree (/var/lib/data), so restic carries it with everything else.
# ghorg refreshes the bare mirrors nightly (it clones on the first run and
# `git remote update`s thereafter), then pgb refreshes
# /var/lib/data/github-mirrors/meta incrementally and a verification step
# writes manifests/<date>/.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.githubBackup;
  # Inside the durable tree, so restic has one source path and the mirrors are
  # backed up with everything else.
  mirrorRoot = "/var/lib/data/github-mirrors";

  # ghorg reads its config from $XDG_CONFIG_HOME/ghorg/conf.yaml; pin it at an
  # empty store dir so a stray root conf can never redirect a backup run.
  emptyConfig = pkgs.runCommand "ghorg-empty-config" { } "mkdir -p $out";

  # The driver's preBackup hook and the full-pass unit run as root with only
  # this PATH. `env -i` scrubs inherited GHORG_* (GHORG_CONFIG, GHORG_DEBUG,
  # GHORG_PRUNE, GHORG_TOKEN_CMD, ...) and `cd /` avoids ghorg's ./ghorg.yaml
  # lookup, so a privileged manual run cannot be redirected by its environment
  # or cwd. The token is passed as a file path, never inlined — these scripts
  # are world-readable in the Nix store.
  mirrorEnv = {
    PATH = lib.makeBinPath [
      pkgs.ghorg
      pkgs.github-backup
      pkgs.gh
      pkgs.git
      pkgs.git-lfs
      pkgs.jq
      pkgs.gawk
      pkgs.gnugrep
      pkgs.findutils
      pkgs.util-linux
      pkgs.coreutils
      pkgs.bash
    ];
    HOME = "/root";
    XDG_CONFIG_HOME = emptyConfig;
    # GIT_CONFIG_GLOBAL pins packing so the mirror does not grow loose objects
    # or get rewritten by auto-maintenance (see the checked-in gitconfig).
    GIT_CONFIG_GLOBAL = "${../features/backup/gitconfig}";
    GHORG_GITHUB_TOKEN = cfg.tokenFile;
    GITHUB_MIRRORS_ROOT = mirrorRoot;
    # github-mirror.sh requires these; `env -i` means nothing else supplies
    # them. GHORG_FETCH_GIT_LFS makes ghorg pull LFS objects, and the probe
    # repo is what proves the token still sees private repos.
    GHORG_ABSOLUTE_PATH_TO_CLONE_TO = mirrorRoot;
    GHORG_PROBE_REPO = cfg.probeRepo;
    GHORG_CLONE_TYPE = "user";
    GHORG_SCM_TYPE = "github";
    GHORG_FETCH_GIT_LFS = "true";
  };
  envArgs = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: value: "${name}=${lib.escapeShellArg value}") mirrorEnv
  );

  # The nightly chain: ghorg refreshes the bare mirrors, then pgb runs
  # incrementally (-i) and the verifier fails the run on a repo-set, count,
  # checkpoint, or fsck mismatch.
  mirror = pkgs.writeShellScript "github-mirror-env" ''
    cd /
    exec ${pkgs.coreutils}/bin/env -i ${envArgs} \
      ${pkgs.bash}/bin/bash -euc '"$1" "$2"; "$3" "$2" "$4"' _ \
        ${../features/backup/github-mirror.sh} ${lib.escapeShellArg config.user.githubUser} \
        ${../features/backup/github-metadata.sh} ${../features/backup/github-verify.sh}
  '';

  # Monthly full pass: no -i, into meta.new, verified, then swapped under the
  # shared host lock. The live meta is only replaced after verification.
  metadataFull = pkgs.writeShellScript "github-metadata-full-env" ''
    cd /
    exec ${pkgs.coreutils}/bin/env -i ${envArgs} \
      GITHUB_METADATA_MODE=full \
      ${pkgs.bash}/bin/bash -euc '"$1" "$2" "$3"' _ \
        ${../features/backup/github-metadata.sh} ${lib.escapeShellArg config.user.githubUser} \
        ${../features/backup/github-verify.sh}
  '';

  # Both units run as root inside the same sandbox: they write only the mirror
  # tree, and /run/lock is the shared host lock the metadata swap takes.
  hardening = {
    User = "root";
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ReadWritePaths = [
      mirrorRoot
      "/run/lock"
    ];
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
  };
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
          description = "Runtime file holding a GitHub token that can read every mirrored repo, read by ghorg, gh, and python-github-backup; never placed in the Nix store. A classic `repo` token also grants write access to every repo the account can reach, so keep it root-only.";
        };
        probeRepo = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "A known-private repo name (required). The run fails unless that repo was refreshed in the current run, catching a token that lost `repo` scope: ghorg then lists only public repos, leaves the old private mirrors in place, and still exits 0.";
        };
        schedule = lib.mkOption {
          type = lib.types.str;
          default = "*-*-* 00:30:00";
          description = "systemd OnCalendar for the nightly mirror timer.";
        };
        timeout = lib.mkOption {
          type = lib.types.str;
          default = "6h";
          description = "systemd TimeSpan cap on a run; generous for a cold clone and the first (non-incremental) metadata fetch of every repo.";
        };
        fullMetadataSchedule = lib.mkOption {
          type = lib.types.str;
          default = "Sun *-*-1..7 09:00:00";
          description = "systemd OnCalendar for the monthly non-incremental metadata pass (first Sunday at 09:00). Runs pgb without -i into meta.new, verifies counts, then swaps meta atomically under the shared host lock; the live meta is kept on failure.";
        };
      };
    };
    default = { };
    description = "Mirror this host's GitHub repos (git via ghorg, issues/PRs via python-github-backup) onto the backup disk; GitHub remains the authoritative copy.";
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
    # out of other users' reach. pgb metadata and manifests inherit the root
    # mode from install(1) inside the scripts.
    systemd.tmpfiles.rules = [
      "d ${mirrorRoot} 0700 root root -"
    ];

    # Only smortress enables githubBackup, so these units exist only there.
    systemd.services.github-mirror = {
      description = "Refresh the GitHub mirrors (git via ghorg, metadata and verify)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${mirror}";
        TimeoutStartSec = cfg.timeout;
      };
    };

    systemd.timers.github-mirror = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
      };
    };

    systemd.services.github-metadata-full = {
      description = "Full non-incremental GitHub metadata backup with verify and swap";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${metadataFull}";
        TimeoutStartSec = "12h";
      };
    };

    systemd.timers.github-metadata-full = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.fullMetadataSchedule;
        Persistent = true;
        Unit = "github-metadata-full.service";
      };
    };
  };
}
