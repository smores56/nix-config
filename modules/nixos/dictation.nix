{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  # whisrs injects text through the Wayland virtual-keyboard protocol on niri,
  # but falls back to /dev/uinput when that protocol regresses — the same
  # failure class the previous ydotool setup guarded against. whisrs only warns
  # when uinput is unreachable, so grant access up front. This mirrors upstream's
  # contrib/99-whisrs.rules with the FHS setfacl path rewritten for NixOS.
  config = lib.mkIf cfg.wayland {
    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", TAG+="uaccess"
      KERNEL=="uinput", SUBSYSTEM=="misc", RUN+="${pkgs.acl}/bin/setfacl -m g:input:rw /dev/$name"
    '';

    users.users.${cfg.username}.extraGroups = [ "input" ];
  };
}
