{ pkgs, ... }: {
  services.swayidle = {
    enable = true;

    timeouts = [
      { timeout = 180; command = "${pkgs.swaylock}/bin/swaylock -fF"; }
      { timeout = 210; command = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off"; }
    ];
    events = [
      { event = "lock"; command = "lock"; }
      { event = "before-sleep"; command = "${pkgs.swaylock}/bin/swaylock -fF"; }
      { event = "after-resume"; command = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on"; }
    ];
  };
}
