{ config, lib, ... }:
{
  options.dotfiles = {
    displayManager = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "pop-os"
        "osx"
        "niri"
      ]);
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
  };

  config.dotfiles.wayland = lib.mkDefault (config.dotfiles.displayManager == "niri");
}
