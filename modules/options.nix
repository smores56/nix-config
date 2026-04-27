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
    terminalFontSize = lib.mkOption {
      type = lib.types.int;
      default = 12;
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
    };
    exposeSsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    fingerprint = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    nixos = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
    };
    darkSystemTheme = lib.mkOption {
      type = lib.types.str;
      default = "rose-pine-moon";
    };
    lightSystemTheme = lib.mkOption {
      type = lib.types.str;
      default = "rose-pine-dawn";
    };
    darkHelixTheme = lib.mkOption {
      type = lib.types.str;
      default = "rose_pine_moon";
    };
    lightHelixTheme = lib.mkOption {
      type = lib.types.str;
      default = "rose_pine_dawn";
    };
    darkModeHook = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
    };
    terminal = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    shell = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    browser = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
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
    dotfiles = {
      wayland = config.dotfiles.displayManager == "niri";
      nixos = config.dotfiles.displayManager == "niri";
      terminal = "wezterm";
      shell = "fish";
      browser = "firefox";
      font = "CaskaydiaCove Nerd Font";
      fontPackage = pkgs.nerd-fonts.caskaydia-cove;
      shellPath = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
    };
  };
}
