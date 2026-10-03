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
    };
  };

  themeAssertion = kind: name: path: {
    assertion = builtins.pathExists path;
    message = "'${name}' not found in ${kind}";
  };
in
{
  options.dotfiles = {
    # ------------------------------------------------------------------
    # Host-authored: per-host knobs. A host sets these in its mkHome /
    # mkNixos call; defaults suit the common case.
    # ------------------------------------------------------------------
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
      ];
      default = "dark";
      description = "Base theme polarity, before the native appearance setting (macOS / Noctalia) takes over at runtime.";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = "smores";
      description = "Primary local username for personal host-level configuration.";
    };
    exposeSsh = lib.mkOption {
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
    search = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host runs the self-hosted SearXNG service behind the agent's web search. NixOS-only.";
    };
    noSleep = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable automatic suspend/sleep at both desktop (noctalia idle) and systemd level. For always-on hosts.";
    };
    nixos = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    fingerprint = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host has a fingerprint reader; enables fprintd and the Noctalia lock screen reader.";
    };
    webProxy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "public exposure of smortress services via Cloudflare Tunnel (NixOS-only)";
          domain = lib.mkOption {
            type = lib.types.str;
            default = "sammohr.dev";
            description = "Apex domain whose subdomains are exposed (e.g. calibre.<domain>).";
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

    # ------------------------------------------------------------------
    # Resolved: read-only values fixed for a given configuration. May be
    # literals or computed from the authored knobs above. Kept as options
    # so any module can read them through the dendritic pattern; a host
    # cannot set them.
    # ------------------------------------------------------------------
    graphical = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Host runs a graphical session (any non-'none' displayManager).";
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
    };
    terminalFontSize = lib.mkOption {
      type = lib.types.int;
      readOnly = true;
    };
    email = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Default git identity.";
    };
    branchPrefix = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Branch prefix for personal repos.";
    };
    codeRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Root directory under which all git repos live. Layout: <codeRoot>/<host>/<owner>/<repo>.";
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
    darkTheme = lib.mkOption {
      type = themeType;
      readOnly = true;
    };
    lightTheme = lib.mkOption {
      type = themeType;
      readOnly = true;
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
      ];

    dotfiles = {
      graphical = config.dotfiles.displayManager != "none";
      wayland = config.dotfiles.displayManager == "niri";
      terminalFontSize = 12;
      email = "sam@sammohr.dev";
      branchPrefix = "smores";
      codeRoot = "${config.home.homeDirectory}/code";
      terminal = "kitty";
      shell = "fish";
      browser = "firefox";
      font = "Google Sans Code";
      fontPackage = pkgs.googlesans-code;
      shellPath = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
      defaultModel = smortress.models.qwen38.id;
      darkTheme = {
        system = "rose-pine-moon";
        helix = "rose_pine_moon";
      };
      lightTheme = {
        system = "rose-pine-dawn";
        helix = "rose_pine_dawn";
      };
    };
  };
}
