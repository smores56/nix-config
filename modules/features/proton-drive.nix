# Proton Drive as an on-demand FUSE mount (`fp`). The command stays in the
# foreground so the mount exists only while it runs; Ctrl-C, a dropped SSH
# session, or closing the terminal unmounts it.
#
# Proton refresh tokens are single-use, so two concurrent rclone clients can
# blank the session (rclone#9880). The nightly backups use the same account
# through a different config, so the mount refuses to start while a backup unit
# is active, and a watcher stops it if a backup begins while it is mounted.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  cfg = config.protonDrive;

  mountPath = "${config.home.homeDirectory}/${cfg.mountPoint}";

  protonMount = pkgs.writeShellApplication {
    name = "proton-mount";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.rclone
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      mountpath=${lib.escapeShellArg mountPath}
      remote=${lib.escapeShellArg cfg.remote}
      grace=${toString cfg.backupGrace}

      # The *-watch units are always running; only the run and full-check units
      # take the Proton credential.
      backup_units() {
        while read -r unit _; do
          case "$unit" in
            *-watch.service | *-dump.service | backup-freshness.service) continue ;;
          esac
          printf '%s\n' "$unit"
        done < <(systemctl list-units --type=service --state=active --no-legend 'backup-*.service' 2>/dev/null || true)
        return 0
      }

      if mountpoint -q "$mountpath" 2>/dev/null; then
        echo "proton-mount: already mounted at $mountpath" >&2
        exit 1
      fi

      # Fail closed rather than racing a backup's token refresh.
      running="$(backup_units)"
      if [[ -n "$running" ]]; then
        printf 'proton-mount: refusing to start while a backup is running:\n%s\n' "$running" >&2
        exit 1
      fi

      mkdir -p "$mountpath"
      printf 'proton-mount: %s -> %s\n' "$remote" "$mountpath" >&2
      printf 'Writable: changes upload when a file closes. Ctrl-C to unmount.\n' >&2

      # Run rclone in the background so a signal to this script alone (not just
      # the terminal's process group) still tears the mount down.
      rclone mount "$remote" "$mountpath" \
        --vfs-cache-mode writes \
        --dir-cache-time 30s \
        --poll-interval 0 \
        --stats-one-line \
        "$@" &
      child=$!
      watcher=""

      cleanup() {
        if [[ -n "$watcher" ]]; then
          kill "$watcher" 2>/dev/null || true
        fi
        if kill -0 "$child" 2>/dev/null; then
          kill -TERM "$child" 2>/dev/null || true
          wait "$child" 2>/dev/null || true
        fi
        if mountpoint -q "$mountpath" 2>/dev/null; then
          # The setuid wrapper from /run/wrappers does the unmount; the store
          # binary cannot mount as an unprivileged user.
          fusermount3 -u "$mountpath" 2>/dev/null ||
            fusermount -u "$mountpath" 2>/dev/null || true
        fi
      }

      # A backup can still start after the guard above. Warn, give in-flight
      # work a grace period, then stop rclone (SIGTERM flushes pending writes).
      watch_backups() {
        while kill -0 "$child" 2>/dev/null; do
          units="$(backup_units)"
          if [[ -n "$units" ]]; then
            printf 'proton-mount: backup started:\n%s\n' "$units" >&2
            printf 'proton-mount: unmounting in %ss unless it finishes first; Ctrl-C now to stop sooner.\n' "$grace" >&2
            sleep "$grace"
            if [[ -z "$(backup_units)" ]]; then
              printf 'proton-mount: backup finished; keeping the mount.\n' >&2
              continue
            fi
            printf 'proton-mount: backup still running; stopping the mount.\n' >&2
            kill -TERM "$child" 2>/dev/null || true
            return 0
          fi
          sleep 5
        done
      }

      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      trap 'exit 129' HUP

      watch_backups &
      watcher=$!

      wait "$child"
    '';
  };
in
{
  options.protonDrive = {
    enable = lib.mkEnableOption "the on-demand Proton Drive FUSE mount (`fp`)";
    mountPoint = lib.mkOption {
      type = lib.types.strMatching "[^/]+";
      default = "proton";
      description = "Directory under the home directory to mount Proton Drive on.";
    };
    remote = lib.mkOption {
      type = lib.types.str;
      default = "proton:";
      description = "rclone remote and path to mount.";
    };
    backupGrace = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds the mount stays up after a backup starts, so in-flight work can finish before rclone is stopped.";
    };
  };

  config = lib.mkIf (isLinux && cfg.enable) {
    home.packages = [ protonMount ];
    user.shellAbbrs.fp = "proton-mount";
  };
}
