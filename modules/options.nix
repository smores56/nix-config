{
  config,
  lib,
  pkgs,
  ...
}:
let
  themeType = lib.types.submodule {
    options = {
      system = lib.mkOption {
        type = lib.types.str;
        description = "Base16 scheme name (must exist in base16-schemes package)";
      };
      helix = lib.mkOption {
        type = lib.types.str;
        description = "Helix theme name (must exist in helix runtime themes)";
      };
      wezterm = lib.mkOption {
        type = lib.types.str;
        description = "Wezterm color scheme name (must match built-in scheme registry)";
      };
      noctalia = lib.mkOption {
        type = lib.types.str;
        description = "Noctalia predefined color scheme name";
      };
    };
  };
in
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
    darkTheme = lib.mkOption {
      type = themeType;
      default = {
        system = "rose-pine-moon";
        helix = "rose_pine_moon";
        wezterm = "Rosé Pine Moon (Gogh)";
        noctalia = "Rose Pine";
      };
    };
    lightTheme = lib.mkOption {
      type = themeType;
      default = {
        system = "rose-pine-dawn";
        helix = "rose_pine_dawn";
        wezterm = "Rosé Pine Dawn (Gogh)";
        noctalia = "Rose Pine";
      };
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
    assertions = [
      {
        assertion = builtins.pathExists "${pkgs.base16-schemes}/share/themes/${config.dotfiles.darkTheme.system}.yaml";
        message = "darkTheme.system '${config.dotfiles.darkTheme.system}' not found in base16-schemes";
      }
      {
        assertion = builtins.pathExists "${pkgs.base16-schemes}/share/themes/${config.dotfiles.lightTheme.system}.yaml";
        message = "lightTheme.system '${config.dotfiles.lightTheme.system}' not found in base16-schemes";
      }
    ];

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
