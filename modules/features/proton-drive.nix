# Proton Drive as an on-demand FUSE mount (`fp`). The command stays in the
# foreground so the mount exists only while it runs; Ctrl-C, a dropped SSH
# session, or closing the terminal unmounts it.
#
# Proton refresh tokens are single-use, so two concurrent rclone clients can
# blank the session (rclone#9880). The nightly backups use the same account
# through a different config, so the mount refuses to start while a backup unit
# is active; do not leave it mounted across the backup windows.
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

      if mountpoint -q "$mountpath" 2>/dev/null; then
        echo "proton-mount: already mounted at $mountpath" >&2
        exit 1
      fi

      # A concurrent refresh blanks the shared Proton session, so fail closed
      # rather than racing a backup. The *-watch units are always running;
      # only the run and full-check units take the Proton credential.
      running=()
      while read -r unit _; do
        case "$unit" in
          *-watch.service | *-dump.service | backup-freshness.service) continue ;;
        esac
        running+=("$unit")
      done < <(systemctl list-units --type=service --state=active --no-legend 'backup-*.service' 2>/dev/null || true)
      if ((''${#running[@]})); then
        printf 'proton-mount: refusing to start while a backup is running:\n  %s\n' "''${running[*]}" >&2
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

      cleanup() {
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
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      trap 'exit 129' HUP

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
  };

  config = lib.mkIf (isLinux && cfg.enable) {
    home.packages = [ protonMount ];
    user.shellAbbrs.fp = "proton-mount";
  };
}
