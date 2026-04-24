{
  lib,
  pkgs,
  displayManager,
  ...
}:
{
  stylix = lib.mkIf (displayManager != null) { targets.zellij.enable = true; };

  programs.zellij = {
    enable = true;
    enableFishIntegration = false;

    extraConfig = ''
      keybinds {
          unbind "Ctrl q"
          shared_except "locked" {
              bind "Alt w" {
                  Run "hq" {
                      floating true
                      close_on_exit true
                  }
              }
              bind "Alt t" {
                  Run "hq" "next" {
                      close_on_exit true
                  }
              }
              bind "Alt a" {
                  Run "hq" "watch" {
                      floating true
                      close_on_exit true
                  }
              }
          }
      }
    '';

    settings = {
      default_shell = "${pkgs.fish}/bin/fish";
      ui.pane_frames.rounded_corners = true;
      session_serialization = false;
      show_startup_tips = false;

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

      load_plugins = {
        "https://github.com/KiryuuLight/zellij-attention/releases/latest/download/zellij-attention.wasm" =
          { };
      };
    };
  };
}
