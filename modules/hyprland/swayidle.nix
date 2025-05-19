{ pkgs, ... }:
{
  home.packages = [ pkgs.swayidle ];

  services.swayidle = {
    # enable = true;

    timeouts = [
      # {
      #   timeout = 295;
      #   command = "${pkgs.libnotify}/bin/notify-send 'Locking in 5 seconds' -t 5000";
      # }
      # {
      #   timeout = 300;
      #   command = "${pkgs.swaylock}/bin/swaylock";
      # }
      {
        timeout = 10;
        command = "if pgrep swaylock; ${pkgs.hyprland}/bin/hyprctl dispatch dpms off; end";
        resumeCommand = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
      }
    ];
    events = [
      {
        event = "before-sleep";
        command = "${pkgs.swaylock}/bin/swaylock";
      }
    ];
  };
}
