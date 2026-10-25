# `pm`: Proton Drive on a client, as an sshfs mount of smortress:/srv/proton.
#
# The server owns the single rclone mount and its token (see
# modules/nixos/proton-drive.nix), so no client ever holds a Proton credential.
# The command stays in the foreground: Ctrl-C or a dropped connection unmounts
# it, and nothing keeps a stale handle on the remote tree.
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
      pkgs.openssh
      pkgs.sshfs
      pkgs.util-linux
    ];
    text = ''
      mountpath=${lib.escapeShellArg mountPath}
      host=smortress
      remote=${lib.escapeShellArg cfg.serverPath}

      # A leftover FUSE mount (a killed sshfs leaves ENOTCONN) or a pm already
      # running here would make sshfs fail with a misleading error, so name it.
      if mountpoint -q "$mountpath"; then
        printf 'proton-mount: %s is already a mountpoint (another pm, or a stale one).\n' "$mountpath" >&2
        printf 'proton-mount: if no pm is running there, clear it with: fusermount3 -uz %s\n' "$mountpath" >&2
        exit 1
      fi

      # sshfs reports the same generic disconnect for a down mount and a refused
      # login, so probe the two separately and name the broken one.
      if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" true; then
        printf 'proton-mount: ssh to %s failed (tunnel down, or your key is not accepted there).\n' "$host" >&2
        printf 'proton-mount: check with: ssh %s true\n' "$host" >&2
        exit 1
      fi
      if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" mountpoint -q "$remote"; then
        printf 'proton-mount: %s has nothing mounted at %s.\n' "$host" "$remote" >&2
        printf 'proton-mount: on %s run: sudo systemctl restart proton-mount (an expired token is the usual cause)\n' "$host" >&2
        exit 1
      fi

      mkdir -p "$mountpath"
      printf 'proton-mount: %s:%s -> %s\n' "$host" "$remote" "$mountpath" >&2
      printf 'Disconnect (network drop, laptop sleep) reconnects; Ctrl-C unmounts.\n' >&2

      # `exec`: sshfs handles SIGINT/SIGTERM by unmounting itself, so there is
      # no wrapper left to trap signals or hang on a dead connection.
      # ConnectTimeout/BatchMode reach ssh (sshfs forwards -o there), so an Access
      # ProxyCommand that cannot complete fails instead of hanging the mount.
      exec sshfs "$host:$remote" "$mountpath" \
        -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks,dir_cache=yes,ConnectTimeout=15,BatchMode=yes
    '';
  };
in
{
  options.protonDrive = {
    enable = lib.mkEnableOption "the on-demand Proton Drive sshfs mount (`pm`)";
    mountPoint = lib.mkOption {
      type = lib.types.strMatching "[^/]+";
      default = "proton";
      description = "Directory under the home directory to mount Proton Drive on.";
    };
    serverPath = lib.mkOption {
      type = lib.types.str;
      default = "/srv/proton";
      description = "Mountpoint of the server's Proton Drive mount (protonDrive.mountPoint on smortress).";
    };
  };

  # Linux only: macOS has no macFUSE here, so smoreswork keeps rsync-only access.
  config = lib.mkIf (isLinux && cfg.enable) {
    home.packages = [
      pkgs.sshfs
      protonMount
    ];
    user.shellAbbrs.pm = "proton-mount";
  };
}
