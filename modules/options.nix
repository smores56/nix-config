{
  config,
  lib,
  pkgs,
  ...
}:
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
      type = lib.types.str;
      readOnly = true;
    };
    shell = lib.mkOption {
      type = lib.types.enum [
        "fish"
      ];
      default = "fish";
    };
    browser = lib.mkOption {
      type = lib.types.str;
      default = "firefox";
    };
    font = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    fontPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
    };
    shellPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
  };

  config = {
    home.packages = [ config.dotfiles.fontPackage ];

    dotfiles = {
      wayland = lib.mkDefault (config.dotfiles.displayManager == "niri");
      terminal = "wezterm";
      font = "CaskaydiaCove Nerd Font";
      fontPackage = pkgs.nerd-fonts.caskaydia-cove;
      shellPath = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
    };
  };
}
