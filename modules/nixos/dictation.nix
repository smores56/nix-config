{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  # whisrs injects text through the Wayland virtual-keyboard protocol on niri,
  # but falls back to /dev/uinput when that protocol regresses — the same
  # failure class the previous ydotool setup guarded against. whisrs only warns
  # when uinput is unreachable, so grant access up front on every device event.
  # MODE/GROUP already give input-group read/write; upstream's extra setfacl
  # only re-asserts them against a competing uinput ACL rule, and none exists
  # here, so it is dropped along with the acl dependency.
  config = lib.mkIf cfg.wayland {
    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", TAG+="uaccess"
    '';

    users.users.${cfg.username}.extraGroups = [ "input" ];
  };
}
