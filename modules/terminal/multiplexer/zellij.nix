{ lib, pkgs, displayManager, ... }: {
  stylix = lib.mkIf (displayManager != null) { targets.zellij.enable = true; };

  programs.zellij = {
    enable = true;
    enableFishIntegration = false;

    settings = {
      default_shell = "${pkgs.fish}/bin/fish";
      ui.pane_frames.rounded_corners = true;
      session_serialization = false;

      themes.default = {
        fg = 7;
        bg = 23;
        black = 0;
        red = 1;
        green = 2;
        yellow = 3;
        blue = 4;
        magenta = 5;
        cyan = 6;
        white = 7;
        orange = 208;
      };
    };
  };
}
