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
      type = lib.types.enum [
        "none"
        "osx"
        "niri"
      ];
      default = "none";
    };
    windowManager = lib.mkOption {
      type = lib.types.enum [
        "none"
        "aerospace"
        "paneru"
      ];
      default = "none";
      description = "macOS tiling window manager. Only meaningful when displayManager is 'osx'.";
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
    username = lib.mkOption {
      type = lib.types.str;
      default = "smores";
      description = "Primary local username for personal host-level configuration.";
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
    };
    email = lib.mkOption {
      type = lib.types.str;
      default = "sam@sammohr.dev";
    };
    branchPrefix = lib.mkOption {
      type = lib.types.str;
      default = "smores";
      description = "Branch prefix for personal (non-work-org) repos (e.g. 'smores').";
    };
    workBranchPrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Branch prefix for work-org repos (e.g. 'sam.mohr'). Null falls back to branchPrefix. Work is detected per-repo via workGithubOrgs.";
    };
    codeRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/code";
      description = "Root directory under which all git repos live (ghq's root). Layout: <codeRoot>/<host>/<owner>/<repo>.";
    };
    workGithubOrgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "GitHub organizations that should use `~/.ssh/id_work` for Git while keeping canonical `github.com` remotes.";
    };
    workModels = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use work-specific models (OpenAI Codex tiers: GPT-5.5 / GPT-5.4 / GPT-5.4-mini) instead of personal models (Xiaomi MiMo + smortress + DeepSeek).";
    };
    ticketPrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Linear team/ticket prefix for work-org repos (e.g. '7AI'). Null = no ticket in work branches.";
    };
    sevenqlLspPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Absolute path to the SevenQL LSP entrypoint on hosts that use it.";
    };
    exposeSsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    fingerprint = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    nvidia = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable proprietary NVIDIA GPU driver. NixOS-only.";
    };
    llm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host runs the llama.cpp LLM service; also disables desktop/system sleep for availability.";
    };
    noSleep = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable automatic suspend/sleep at both desktop (noctalia idle) and systemd level. For always-on hosts.";
    };
    persist = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host uses /persist for impermanence. NixOS-only.";
    };
    primaryMonitor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Primary monitor name for desktop widgets (e.g. eDP-1, DP-1).";
    };
    monitorSize = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            width = lib.mkOption { type = lib.types.int; };
            height = lib.mkOption { type = lib.types.int; };
          };
        }
      );
      default = null;
      description = "Primary monitor resolution. Used to compute desktop widget positions.";
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
        noctalia = "Rose Pine";
      };
    };
    lightTheme = lib.mkOption {
      type = themeType;
      default = {
        system = "rose-pine-dawn";
        helix = "rose_pine_dawn";
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
    defaultModel = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Default local LLM model for AI coding tools.";
    };
    webProxy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "public exposure of smortress services via Cloudflare Tunnel (NixOS-only)";
          domain = lib.mkOption {
            type = lib.types.str;
            default = "sammohr.dev";
            description = "Apex domain whose subdomains are exposed (e.g. opencode.<domain>).";
          };
          tunnelId = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Cloudflare Tunnel UUID from `cloudflared tunnel create`. Empty leaves the tunnel daemon off until credentials are provisioned.";
          };
          credentialsFile = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/cloudflared/credentials.json";
            description = "Path to the tunnel credentials JSON on the host. Kept out of the Nix store; provisioned out-of-band.";
          };
        };
      };
      default = { };
      description = "Public exposure of smortress HTTP services over Cloudflare Tunnel. TLS terminates at the Cloudflare edge; cloudflared proxies each subdomain straight to its loopback service.";
    };
    herdr = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Herdr terminal multiplexer config (binary installed manually)" // {
            default = true;
          };
          theme = lib.mkOption {
            type = lib.types.str;
            default = "gruvbox";
            description = "Herdr built-in theme name.";
          };
        };
      };
      default = { };
      description = "Herdr terminal workspace manager settings.";
    };
    aiHints = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "AI coding assistant context/rules, shared across maki and opencode.";
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
          assertion =
            config.dotfiles.polarity != "time-of-day"
            || config.dotfiles.displayManager == "osx"
            || config.dotfiles.displayManager == "niri";
          message = "polarity 'time-of-day' requires displayManager 'osx' or 'niri' for automatic switching";
        }
      ];

    dotfiles = {
      wayland = config.dotfiles.displayManager == "niri";
      terminal = "kitty";
      shell = "fish";
      browser = "firefox";
      font = "Google Sans Code";
      fontPackage = pkgs.googlesans-code;
      shellPath = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
      defaultModel = "gemma-4-31b";
    };
  };
}
