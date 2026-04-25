{ config, lib, ... }:
{
  options.dotfiles = {
    displayManager = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "pop-os"
          "osx"
          "niri"
        ]
      );
      default = null;
    };
    polarity = lib.mkOption {
      type = lib.types.enum [
        "light"
        "dark"
      ];
      default = "dark";
    };
    helixTheme = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    terminalFontSize = lib.mkOption {
      type = lib.types.int;
      default = 12;
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    exposeSsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    terminal = lib.mkOption {
      type = lib.types.enum [
        "wezterm"
        "kitty"
        "alacritty"
        "ghostty"
      ];
      default = "wezterm";
    };
    shell = lib.mkOption {
      type = lib.types.enum [
        "fish"
        "zsh"
        "bash"
      ];
      default = "fish";
    };
  };

  config.dotfiles.wayland = lib.mkDefault (config.dotfiles.displayManager == "niri");
}
