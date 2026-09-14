{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  # ydotool is the fallback text injector for dictation (see decision 5 in the
  # dictation design). niri implements zwp_virtual_keyboard_manager_v1 so wtype
  # is the primary path, but that protocol has regressed before; ydotool types
  # through /dev/uinput and is immune to it. programs.ydotool provides the
  # ydotoold service, the `ydotool` group, and a system-wide YDOTOOL_SOCKET.
  config = lib.mkIf cfg.wayland {
    programs.ydotool.enable = true;
    users.users.${cfg.username}.extraGroups = [ "ydotool" ];
  };
}
