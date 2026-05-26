# SmolVM microVM runtime — full NixOS declaration.
# On standard distros `smolvm setup` installs packages, udev rules, a loopfs
# helper, and sudoers config. NixOS has a read-only /etc and /usr, so we
# declare everything here instead and skip `smolvm setup` entirely.
{ pkgs, ... }:
let
  # Privileged helper for SmolVM image-build loop mounts.
  # Equivalent to /usr/local/libexec/smolvm-loopfs-helper on other distros.
  smolvm-loopfs-helper = pkgs.writeShellScriptBin "smolvm-loopfs-helper" ''
    set -euo pipefail
    SCRIPT_NAME="$(basename "$0")"
    RUNTIME_USER="''${SUDO_USER:-}"
    RUNTIME_UID=""
    if [[ -n "''${RUNTIME_USER}" ]]; then
      RUNTIME_UID="$(id -u "''${RUNTIME_USER}")"
    fi
    die() { echo "❌ ''${SCRIPT_NAME}: $1" >&2; exit 1; }
    resolve_abs() { local input="$1"; [[ "''${input}" = /* ]] || die "path must be absolute: ''${input}"; readlink -f -- "''${input}"; }
    require_owner() {
      local path="$1"
      if [[ -z "''${RUNTIME_UID}" ]]; then return 0; fi
      local owner_uid; owner_uid="$(stat -c %u -- "''${path}")"
      [[ "''${owner_uid}" == "''${RUNTIME_UID}" ]] || die "path must be owned by runtime user ''${RUNTIME_USER}: ''${path}"
    }
    require_parent_owner() { require_owner "$(dirname -- "$1")"; }
    case "''${1:-}" in
      mount)
        [[ $# -eq 3 ]] || die "mount requires: <rootfs.ext4> <mount_dir>"
        rootfs="$(resolve_abs "$2")"; mnt="$(resolve_abs "$3")"
        [[ -f "''${rootfs}" ]] || die "rootfs is not a regular file: ''${rootfs}"
        [[ "''${rootfs}" == *.ext4 ]] || die "rootfs must end with .ext4: ''${rootfs}"
        [[ -d "''${mnt}" ]] || die "mount dir does not exist: ''${mnt}"
        require_owner "''${rootfs}"; require_owner "''${mnt}"
        mount -o loop "''${rootfs}" "''${mnt}"
        ;;
      extract)
        [[ $# -eq 3 ]] || die "extract requires: <rootfs.tar> <mount_dir>"
        tarfile="$(resolve_abs "$2")"; mnt="$(resolve_abs "$3")"
        [[ -f "''${tarfile}" ]] || die "tar path is not a regular file: ''${tarfile}"
        [[ "''${tarfile}" == *.tar ]] || die "tar path must end with .tar: ''${tarfile}"
        [[ -d "''${mnt}" ]] || die "mount dir does not exist: ''${mnt}"
        require_owner "''${tarfile}"; require_parent_owner "''${mnt}"
        tar -xf "''${tarfile}" -C "''${mnt}"
        ;;
      umount)
        [[ $# -eq 2 ]] || die "umount requires: <mount_dir>"
        mnt="$(resolve_abs "$2")"
        [[ -d "''${mnt}" ]] || die "mount dir does not exist: ''${mnt}"
        require_parent_owner "''${mnt}"
        umount "''${mnt}"
        ;;
      --help|-h|"")
        echo "Usage: ''${SCRIPT_NAME} mount <rootfs.ext4> <mount_dir>"
        echo "       ''${SCRIPT_NAME} extract <rootfs.tar> <mount_dir>"
        echo "       ''${SCRIPT_NAME} umount <mount_dir>"
        ;;
      *) die "unknown subcommand: $1" ;;
    esac
  '';

  # Stable binary paths via NixOS system profile.
  bin = name: "/run/current-system/sw/bin/${name}";
in
{
  environment.systemPackages = [
    pkgs.firecracker
    pkgs.nftables
    pkgs.wget
    pkgs.gnutar
    smolvm-loopfs-helper
  ];

  # SmolVM expects /dev/kvm with group=kvm, mode=0660.
  services.udev.extraRules = ''
    KERNEL=="kvm", GROUP="kvm", MODE="0660", TAG+="uaccess"
  '';

  users.groups.kvm = { };

  # Scoped NOPASSWD sudo for SmolVM runtime commands.
  # Mirrors what `smolvm setup --configure-runtime` writes to /etc/sudoers.d
  # on other distros. NixOS has a read-only /etc, so we declare it here.
  security.sudo.extraRules = [
    {
      users = [ "smores" ];
      commands =
        let
          # Network commands: ip, nft, sysctl
          netCmds = map (c: { command = c; options = [ "NOPASSWD" ]; }) [
            (bin "ip")
            (bin "nft")
            (bin "sysctl")
          ];
          # VM commands: firecracker, kill
          vmCmds = map (c: { command = c; options = [ "NOPASSWD" ]; }) [
            (bin "firecracker")
            (bin "kill")
          ];
          # Image build helper
          imgCmds = [
            { command = bin "smolvm-loopfs-helper"; options = [ "NOPASSWD" ]; }
          ];
        in
        netCmds ++ vmCmds ++ imgCmds;
    }
  ];
}
