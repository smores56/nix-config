# Mirror GitHub repos into the durable tree with ghorg, plus metadata outside git
# (issues, PRs, discussions, releases) with python-github-backup; restic carries it.
# Nightly: ghorg refresh, incremental pgb into meta, then verification writes
# manifests/<date>/.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.githubBackup;
  # Runtime path to a token that can read every mirrored repo. A path in a derivation
  # would copy the token into the store, so it stays a string. A classic `repo` token
  # also grants write access: keep it root-only.
  tokenFile = "/run/secrets/github-repo-pat";
  # systemd OnCalendar for the nightly mirror timer.
  schedule = "*-*-* 00:30:00";
  # Generous for a cold clone and the first full metadata fetch.
  timeout = "6h";
  # Monthly full metadata pass (no -i) into meta.new; verified, then swapped under the
  # shared host lock. The live meta is kept on failure.
  fullMetadataSchedule = "Sun *-*-1..7 09:00:00";
  mirrorRoot = "/var/lib/data/github-mirrors";

  # ghorg reads its config from $XDG_CONFIG_HOME/ghorg/conf.yaml; pin it at an
  # empty store dir so a stray root conf can never redirect a backup run.
  emptyConfig = pkgs.runCommand "ghorg-empty-config" { } "mkdir -p $out";

  # Root-run with only this PATH. `env -i` scrubs inherited GHORG_* and `cd /` avoids
  # ghorg's ./ghorg.yaml lookup, so the environment or cwd cannot redirect a run. The
  # token is a file path: these scripts are world-readable in the store.
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
    GHORG_GITHUB_TOKEN = tokenFile;
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

  mirror = pkgs.writeShellScript "github-mirror-env" ''
    cd /
    exec ${pkgs.coreutils}/bin/env -i ${envArgs} \
      ${pkgs.bash}/bin/bash -euc '"$1" "$2"; "$3" "$2" "$4"' _ \
        ${../features/backup/github-mirror.sh} ${lib.escapeShellArg config.user.githubUser} \
        ${../features/backup/github-metadata.sh} ${../features/backup/github-verify.sh}
  '';

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
  hardening = (import ../lib/hardening.nix) // {
    User = "root";
    UMask = "0077";
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
        probeRepo = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "A known-private repo name (required). The run fails unless that repo was refreshed in the current run, catching a token that lost `repo` scope: ghorg then lists only public repos, leaves the old private mirrors in place, and still exits 0.";
        };
      };
    };
    default = { };
    description = "Mirror this host's GitHub repos (git via ghorg, issues/PRs via python-github-backup) onto the backup disk; GitHub remains the authoritative copy.";
  };

  config = {
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

    systemd.services.github-mirror = {
      description = "Refresh the GitHub mirrors (git via ghorg, metadata and verify)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${mirror}";
        TimeoutStartSec = timeout;
      };
    };

    systemd.timers.github-mirror = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = schedule;
        Persistent = true;
      };
    };

    systemd.services.github-metadata-full = {
      description = "Full non-incremental GitHub metadata backup with verify and swap";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${metadataFull}";
        TimeoutStartSec = "12h";
      };
    };

    systemd.timers.github-metadata-full = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = fullMetadataSchedule;
        Persistent = true;
        Unit = "github-metadata-full.service";
      };
    };
  };
}
