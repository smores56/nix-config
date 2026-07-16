{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) smortress;
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

  themeAssertion = kind: name: path: {
    assertion = builtins.pathExists path;
    message = "'${name}' not found in ${kind}";
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
      default =
        if config.dotfiles.work.email != null then config.dotfiles.work.email else "sam@sammohr.dev";
    };
    branchPrefix = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Branch prefix for personal (non-work-org) repos.";
    };
    work = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable work-specific identity, repo, model, and MCP defaults.";
          };
          email = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Work email address. Null leaves dotfiles.email at its personal default.";
          };
          branchPrefix = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Branch prefix for work-org repos. Null falls back to dotfiles.branchPrefix.";
          };
          ticketPrefix = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Linear team/ticket prefix for work-org repos. Null = no ticket in work branches.";
          };
          githubOrgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "GitHub organizations that should use work repo identity and ~/.ssh/id_work.";
          };
        };
      };
      default = { };
      description = "Work profile configuration shared by Git, repo helpers, AI tools, and MCPs.";
    };
    codeRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/code";
      description = "Root directory under which all git repos live. Layout: <codeRoot>/<host>/<owner>/<repo>.";
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
      readOnly = true;
    };
    lightTheme = lib.mkOption {
      type = themeType;
      readOnly = true;
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
            description = "Apex domain whose subdomains are exposed (e.g. git.<domain>).";
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
    calibre = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "calibre-server OPDS as a user systemd service";
          port = lib.mkOption {
            type = lib.types.port;
            default = 8181;
            description = "Loopback port for calibre-server.";
          };
        };
      };
      default = { };
      description = "calibre OPDS content server exposed over the Cloudflare Tunnel.";
    };
    aiHints = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "AI coding assistant context/rules, shared across AI coding assistants.";
    };
  };
  config = {
    assertions =
      let
        helixThemes = "${pkgs.helix-unwrapped.src}/runtime/themes";
      in
      [
        (themeAssertion "base16-schemes" config.dotfiles.darkTheme.system
          "${pkgs.base16-schemes}/share/themes/${config.dotfiles.darkTheme.system}.yaml"
        )
        (themeAssertion "base16-schemes" config.dotfiles.lightTheme.system
          "${pkgs.base16-schemes}/share/themes/${config.dotfiles.lightTheme.system}.yaml"
        )
        (themeAssertion "helix themes" config.dotfiles.darkTheme.helix
          "${helixThemes}/${config.dotfiles.darkTheme.helix}.toml"
        )
        (themeAssertion "helix themes" config.dotfiles.lightTheme.helix
          "${helixThemes}/${config.dotfiles.lightTheme.helix}.toml"
        )
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
      defaultModel = smortress.models.gemma431b.id;
      branchPrefix = "smores";
      darkTheme = {
        system = "rose-pine-moon";
        helix = "rose_pine_moon";
        noctalia = "Rose Pine";
      };
      lightTheme = {
        system = "rose-pine-dawn";
        helix = "rose_pine_dawn";
        noctalia = "Rose Pine";
      };
    };
  };
}
