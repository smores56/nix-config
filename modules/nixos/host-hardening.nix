# Hardening for a host where an unattended assistant runs as the owner: no
# sudo ticket for a later command to ride, no cross-process ptrace, and no
# other users' processes in /proc. What it cannot fix is in docs/kanbei-split.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hostHardening;
in
{
  options.hostHardening.enable = lib.mkEnableOption "Kanbei host hardening (no sudo ticket, no ptrace, hidden processes)";

  config = lib.mkIf cfg.enable {
    # One writer per Defaults option: ssh.nix renders the single
    # `Defaults timestamp_timeout` line from its own option, and this module
    # sets that option to 0 (one touch per command, not a 15-minute ticket) and
    # adds `use_pty`, so a process left behind in the caller's terminal cannot
    # feed keystrokes to the root command.
    sudoTicketTimeout = 0;
    security.sudo.extraConfig = "Defaults use_pty";

    # Yama's default (1) lets any same-uid process attach; 2 restricts ptrace
    # to a parent or CAP_SYS_PTRACE.
    boot.kernel.sysctl."kernel.yama.ptrace_scope" = 2;

    # hidepid hides other users' /proc entries. NixOS dropped
    # security.hideProcessInformation (its remount does not survive cgroups v2),
    # so this owns the remount; `proc` is the kernel's allow-list group for
    # units that must still see every process. The gid is pinned: the mount
    # string needs the number at build time, and a free gid is only chosen at
    # activation otherwise.
    users.groups.proc.gid = config.ids.gids.proc;
    systemd.services.proc-hidepid = {
      description = "Mount /proc with hidepid=2 and the proc-group allow-list";
      wantedBy = [ "multi-user.target" ];
      # A login that lands before the remount would still see every process.
      before = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.util-linux}/bin/mount -o remount,hidepid=2,gid=${toString config.ids.gids.proc} /proc";
        ExecStop = "${pkgs.util-linux}/bin/mount -o remount,hidepid=0 /proc";
      };
    };

    # systemd insists on reading /proc across uids (PID 1, every user's
    # processes); upstream refuses hidepid on user managers without the group
    # (systemd#12955). Root services need neither — CAP_SYS_PTRACE already
    # bypasses hidepid.
    systemd.services.systemd-logind.serviceConfig.SupplementaryGroups = [ "proc" ];
    systemd.services."user@".serviceConfig.SupplementaryGroups = [ "proc" ];

    assertions = [
      {
        assertion = config.exposeSsh.enable || config.sudoKey.enable;
        message = "host-hardening sets sudoTicketTimeout, which modules/nixos/ssh.nix renders only when exposeSsh or sudoKey is on; enable one of them or the stale ticket stays";
      }
      {
        assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "5.8";
        message = "hidepid is a per-mount option only from Linux 5.8; on an older kernel it hides processes for the whole user namespace and breaks systemd";
      }
    ];
  };
}
