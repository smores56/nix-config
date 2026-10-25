# Proton Drive as one host-owned FUSE mount at /srv/proton.
#
# Only this mount ever authenticates to Proton: the refresh token lives in
# /var/lib/proton/rclone.conf, readable by the `proton` user alone, and every
# consumer (the offsite backup units, `pm` on clients over sshfs) reads and
# writes files through the mount. Proton refresh tokens are single-use
# (rclone#9880), so a second client holding its own copy would blank this one.
# Proton rewrites the token in place on refresh, which is why the file is
# created at runtime by the operator: a sops copy would be immutable and go
# stale, breaking auth on the next refresh.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.protonDrive;

  stateDir = "/var/lib/proton";
  configFile = "${stateDir}/rclone.conf";
  # The mount's own rclone RC endpoint. The health check and the backup driver
  # ask the mount process itself about the backend and its upload queue, so no
  # consumer ever opens a second Proton client (the refresh token is single-use,
  # rclone#9880). The socket lives in the 0700 state dir, so only proton and root
  # can reach it -- which is what makes --rc-no-auth safe.
  rcSocket = "${stateDir}/rc.sock";
  alertUnit = lib.optional (config.alerting.enable or false) "cloudflare-email@%n.service";

  # NixOS renders every `path` entry as `<entry>/bin` and `<entry>/sbin`, so the
  # entry that yields the setuid wrapper directory is "/run/wrappers" (not
  # "/run/wrappers/bin", which would render as /run/wrappers/bin/bin). Without
  # it `fusermount3` resolves to the store's non-setuid copy that the rclone
  # wrapper appends to PATH, and an unprivileged mount dies with
  # "fusermount: exit status 1".
  wrappersPath = "/run/wrappers";

  # Runs as the service user, so this is exactly the readability rclone gets.
  precheck = pkgs.writeShellScript "proton-mount-precheck" ''
    if [ ! -r ${lib.escapeShellArg configFile} ]; then
      echo "proton-mount: ${configFile} is missing or unreadable by the proton user." >&2
      echo "proton-mount: create it as the proton user (docs/manual-steps.md, section" >&2
      echo "'Proton mount (smortress)'), then run: systemctl restart proton-mount" >&2
      exit 1
    fi
  '';

  # `mountpoint -q` only proves the kernel still holds the mount, and an expired
  # token leaves rclone running with every read failing -- yet `ls -A` still
  # exits 0, because it lists the VFS's cached root. So query the backend through
  # the mount's own RC: `operations/list` performs a real API call inside the
  # mount process, with the mount's config and token.
  health = pkgs.writeShellApplication {
    name = "proton-mount-health";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.rclone
      pkgs.util-linux
    ];
    text = ''
      if ! mountpoint -q ${lib.escapeShellArg cfg.mountPoint}; then
        echo "${cfg.mountPoint} is not a mountpoint; proton-mount.service is down" >&2
        exit 1
      fi
      if ! timeout 120 rclone rc --unix-socket ${lib.escapeShellArg rcSocket} \
        operations/list fs=${lib.escapeShellArg cfg.remote} remote= >/dev/null; then
        echo "listing ${cfg.mountPoint} through the mount's RC failed; the Proton token is probably expired" >&2
        exit 1
      fi
    '';
  };
in
{
  options.protonDrive = {
    enable = lib.mkEnableOption "the shared Proton Drive FUSE mount (the single rclone token owner)";
    mountPoint = lib.mkOption {
      type = lib.types.path;
      default = "/srv/proton";
      description = "Absolute path the Proton tree is mounted at.";
    };
    remote = lib.mkOption {
      type = lib.types.str;
      default = "proton:";
      description = "rclone remote and path to mount.";
    };
  };

  config = lib.mkIf cfg.enable {
    # An unprivileged rclone mount goes through the setuid fusermount3 helper,
    # and --allow-other is refused without user_allow_other in /etc/fuse.conf.
    programs.fuse.enable = true;
    programs.fuse.userAllowOther = true;

    # The group carries the mount's write permission (rclone --umask 007). The
    # token itself stays 0600, so membership grants files, never the credential.
    users.groups.proton = { };
    users.users.proton = {
      isSystemUser = true;
      group = "proton";
      home = stateDir;
    };
    users.users.${config.machine.username}.extraGroups = [ "proton" ];

    systemd.tmpfiles.rules = [
      # Unmounted, the path is a plain root-owned directory, group proton, never
      # world-writable: a down mount cannot be used to fill the root filesystem,
      # and only proton/root (plus group proton) can even enter it. Group write
      # is required because fusermount3 refuses a mountpoint the mounting user
      # cannot write ("user has no write access to mountpoint"). While mounted,
      # the FUSE root's own 0770 proton:proton modes take over.
      "d ${cfg.mountPoint} 0770 root proton -"
    ];

    systemd.services.proton-mount = {
      description = "Proton Drive FUSE mount (single rclone token owner)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # The setuid helper must win over the store's non-setuid fuse3, which the
      # rclone wrapper appends to PATH.
      path = lib.mkBefore [ wrappersPath ];
      unitConfig = {
        # A missing config restarts into the start limit instead of looping (and
        # emailing) every 30s; the health timer keeps reporting the outage.
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 5;
      };
      onFailure = alertUnit;
      serviceConfig = {
        # rclone mount speaks sd_notify: READY=1 once the mountpoint is live, so
        # dependents start against a working mount.
        Type = "notify";
        User = "proton";
        Group = "proton";
        # rclone's own files (VFS cache, config rewrites, the RC socket) stay
        # private; what the mount presents is governed by --umask below.
        UMask = "0077";
        StateDirectory = "proton";
        StateDirectoryMode = "0700";
        # An unclean stop can leave the RC socket behind; binding over it fails
        # the next start, which Restart=always would loop on. The precheck runs
        # first so a missing config still gets the actionable message.
        ExecStartPre = [
          precheck
          "${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg rcSocket}"
        ];
        ExecStart = lib.escapeShellArgs [
          "${pkgs.rclone}/bin/rclone"
          "mount"
          cfg.remote
          (toString cfg.mountPoint)
          "--config"
          configFile
          "--cache-dir"
          "${stateDir}/cache"
          "--vfs-cache-mode"
          "writes"
          "--vfs-cache-max-size"
          "10G"
          "--vfs-cache-max-age"
          "24h"
          "--allow-other"
          # allow-other alone lets every local user in through the FUSE root
          # (0777 before the umask). default-permissions makes the kernel check
          # the 0660/0770 modes against the caller, and umask 007 grants them to
          # group proton only -- so only proton/root and group proton get in.
          "--default-permissions"
          "--umask"
          "007"
          # Long enough that a backup's walk over the whole tree reads one cached
          # listing instead of re-listing every directory from Proton every
          # minute (~2s per directory, which dominated a Photos run). Writers
          # through the mount invalidate their own entries, so this only delays
          # changes made elsewhere (phone/web) until the next re-list or restart.
          "--dir-cache-time"
          "1h"
          "--poll-interval"
          "0"
          "--protondrive-enable-caching=false"
          "--protondrive-replace-existing-draft=true"
          # The RC endpoint the health check and the backup drain use. No auth:
          # the socket is only reachable inside the 0700 state dir.
          "--rc"
          "--rc-addr"
          rcSocket
          "--rc-no-auth"
          "--rc-web-gui=false"
          "--log-level"
          "INFO"
        ];
        # Lazy unmount before systemd signals rclone, so a hung Proton read cannot
        # wedge the stop; a failed umount must not fail the stop either. `+` runs
        # it as root: the store's fusermount3 is not the setuid wrapper.
        ExecStop = "+${pkgs.bash}/bin/bash -c '${pkgs.fuse3}/bin/fusermount3 -uz ${lib.escapeShellArg (toString cfg.mountPoint)} 2>/dev/null || true'";
        # -uz only detaches, so bound the teardown instead of the default 90s.
        TimeoutStopSec = "30s";
        # Restart=always also recovers a mount rclone gives up on by itself (a
        # clean exit); an explicit `systemctl stop` is still respected.
        Restart = "always";
        RestartSec = 30;
        # Hardening stays minimal on purpose: rclone mounts through the setuid
        # fusermount3 helper, which NoNewPrivileges (and a strict
        # ProtectSystem/ReadWritePaths view) would block, and allow-other
        # consumers must still write through the mount.
        #
        # Never add PrivateTmp or PrivateMounts here: either gives the unit its
        # own mount namespace, so the FUSE mount would exist only inside it and
        # the host, the health check, and the backup's mountpoint preflight would
        # all see the empty underlying directory instead.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    # Auth failures never exit rclone, so nothing restarts or alerts by itself;
    # the health check asks the backend directly and fails this oneshot, whose
    # onFailure is the alert path.
    systemd.services.proton-mount-health = {
      description = "Proton Drive mount health check (an expired token keeps the mount alive)";
      onFailure = alertUnit;
      serviceConfig = {
        Type = "oneshot";
        User = "proton";
        Group = "proton";
        ExecStart = "${health}/bin/proton-mount-health";
        TimeoutStartSec = "3m";
      };
    };

    systemd.timers.proton-mount-health = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:17:00";
        # Report the first check missed while the host was off on the next boot.
        Persistent = true;
      };
    };

    # The operator re-auths with `sudo -u proton rclone ...`.
    environment.systemPackages = [ pkgs.rclone ];
  };
}
