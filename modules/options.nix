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
    polarity = lib.mkOption {
      type = lib.types.enum [
        "dark"
        "light"
        "time-of-day"
      ];
      default = "dark";
      description = "Theme polarity. 'dark' and 'light' set a fixed theme; 'time-of-day' enables automatic switching via macOS auto-appearance or Noctalia location scheduling.";
    };
    terminalFontSize = lib.mkOption {
      type = lib.types.int;
      default = 12;
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
    };
    email = lib.mkOption {
      type = lib.types.str;
      default = "sam@sammohr.dev";
    };
    exposeSsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    fingerprint = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    ollama = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Ollama LLM service with NVIDIA CUDA support. NixOS-only.";
    };
    nixos = lib.mkOption {
      type = lib.types.bool;
      default = false;
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
      description = "Script path. Accepts optional $1: 'true' (dark) or 'false' (light). Falls back to gsettings detection if omitted.";
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
    assertions =
      let
        helixThemes = "${pkgs.helix-unwrapped.src}/runtime/themes";
      in
      [
        {
          assertion = builtins.pathExists "${pkgs.base16-schemes}/share/themes/${config.dotfiles.darkTheme.system}.yaml";
          message = "darkTheme.system '${config.dotfiles.darkTheme.system}' not found in base16-schemes";
        }
        {
          assertion = builtins.pathExists "${pkgs.base16-schemes}/share/themes/${config.dotfiles.lightTheme.system}.yaml";
          message = "lightTheme.system '${config.dotfiles.lightTheme.system}' not found in base16-schemes";
        }
        {
          assertion = builtins.pathExists "${helixThemes}/${config.dotfiles.darkTheme.helix}.toml";
          message = "darkTheme.helix '${config.dotfiles.darkTheme.helix}' not found in helix themes";
        }
        {
          assertion = builtins.pathExists "${helixThemes}/${config.dotfiles.lightTheme.helix}.toml";
          message = "lightTheme.helix '${config.dotfiles.lightTheme.helix}' not found in helix themes";
        }
        {
          assertion = config.dotfiles.polarity != "time-of-day"
            || config.dotfiles.displayManager == "osx"
            || config.dotfiles.displayManager == "niri";
          message = "polarity 'time-of-day' requires displayManager 'osx' or 'niri' for automatic switching";
        }
      ];

    dotfiles = {
      wayland = config.dotfiles.displayManager == "niri";
      terminal = "wezterm";
      shell = "fish";
      browser = "firefox";
      font = "CaskaydiaCove Nerd Font";
      fontPackage = pkgs.nerd-fonts.caskaydia-cove;
      shellPath = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
    };
  };
}
