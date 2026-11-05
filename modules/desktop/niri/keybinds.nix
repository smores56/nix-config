{
  config,
  lib,
  ...
}:
let
  # Documented Noctalia IPC form; niri runs `spawn` and `spawn-sh` through transient systemd units anyway.
  noctalia = cmd: "noctalia msg ${cmd}";

  shared = import ../shared-bindings.nix { inherit lib; };
  sharedBinds = builtins.listToAttrs (
    map (binding: {
      name = shared.niriKey binding;
      value.action = binding.niri;
    }) shared.bindings
  );
in
{
  # Super+Tab needs no bind here: niri's recent-windows switcher ships it by default, as long as no
  # `recent-windows.binds` block replaces the defaults.
  programs.niri.settings = {
    # Disjoint: a plain merge would let a shared chord silently overwrite a local one.
    binds = lib.attrsets.unionOfDisjoint (
      {
        "Super+Alt+C".action.spawn-sh = noctalia "panel-toggle control-center";
        "Mod+O".action.toggle-overview = [ ];
        "Mod+Shift+Space".action.switch-layout = "prev";
        # The escape hatch when a VM or remote desktop has grabbed every key; Super+Esc is lock.
        "Mod+Shift+Escape".action.toggle-keyboard-shortcuts-inhibit = [ ];

        "XF86AudioRaiseVolume".action.spawn = [
          "wpctl"
          "set-volume"
          "-l"
          "1.0"
          "@DEFAULT_AUDIO_SINK@"
          "0.1+"
        ];
        "XF86AudioLowerVolume".action.spawn = [
          "wpctl"
          "set-volume"
          "@DEFAULT_AUDIO_SINK@"
          "0.1-"
        ];
        "XF86AudioMute".action.spawn = [
          "wpctl"
          "set-mute"
          "@DEFAULT_AUDIO_SINK@"
          "toggle"
        ];
        "XF86AudioMicMute".action.spawn = [
          "wpctl"
          "set-mute"
          "@DEFAULT_AUDIO_SOURCE@"
          "toggle"
        ];
        "XF86MonBrightnessUp".action.spawn = [
          "brightnessctl"
          "set"
          "+10%"
        ];
        "XF86MonBrightnessDown".action.spawn = [
          "brightnessctl"
          "set"
          "10%-"
        ];
        "XF86AudioPlay".action.spawn = [
          "playerctl"
          "play-pause"
        ];
        "XF86AudioPause".action.spawn = [
          "playerctl"
          "play-pause"
        ];
        "XF86AudioStop".action.spawn = [
          "playerctl"
          "stop"
        ];
        "XF86AudioPrev".action.spawn = [
          "playerctl"
          "previous"
        ];
        "XF86AudioNext".action.spawn = [
          "playerctl"
          "next"
        ];

        "Mod+WheelScrollDown" = {
          cooldown-ms = 150;
          action.focus-workspace-down = [ ];
        };
        "Mod+WheelScrollUp".action.focus-workspace-up = [ ];
        "Mod+Ctrl+WheelScrollDown".action.move-column-to-workspace-down = [ ];
        "Mod+Ctrl+WheelScrollUp".action.move-column-to-workspace-up = [ ];
        "Mod+WheelScrollRight".action.focus-column-right = [ ];
        "Mod+WheelScrollLeft".action.focus-column-left = [ ];
        "Mod+Ctrl+WheelScrollRight".action.move-column-right = [ ];
        "Mod+Ctrl+WheelScrollLeft".action.move-column-left = [ ];
        "Mod+Shift+WheelScrollDown".action.focus-column-right = [ ];
        "Mod+Shift+WheelScrollUp".action.focus-column-left = [ ];
        "Mod+Ctrl+Shift+WheelScrollDown".action.move-column-right = [ ];
        "Mod+Ctrl+Shift+WheelScrollUp".action.move-column-left = [ ];
      }
      // shared.screenshots.niri
    ) sharedBinds;
  };
}
