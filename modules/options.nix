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
      description = "Prefix for git branch names (e.g. 'sam.mohr').";
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
      description = "Use work-specific models (OpenAI Codex GPT 5.5 + Claude Opus 4.8) instead of personal models (Xiaomi MiMo + smortress + DeepSeek).";
    };
    ticketPrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Ticket ID prefix for branch names (e.g. '7AI'). Null for no ticket requirement.";
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
    opencodeHost = lib.mkOption {
      type = lib.types.submodule {
        options = {
          hostname = lib.mkOption {
            type = lib.types.str;
            default = "smortress";
            description = "Hostname clients should use to reach the hosted opencode server.";
          };
          bindAddress = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Address the opencode and OpenChamber services bind to. Null means this host does not run opencode services.";
          };
          opencodePort = lib.mkOption {
            type = lib.types.port;
            default = 4000;
            description = "Port for the opencode server.";
          };
          openchamberPort = lib.mkOption {
            type = lib.types.port;
            default = 3000;
            description = "Port for the OpenChamber web UI.";
          };
        };
      };
      default = { };
      description = "Host and port settings for a hosted opencode/OpenChamber pair. Set bindAddress to enable services.";
    };
    paseo = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Paseo daemon for remote agent access.";
          };
          web = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Serve the Paseo web app (Expo SPA) via Caddy reverse proxy.";
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  default = 8765;
                  description = "HTTP port for Caddy to serve the web app on.";
                };
              };
            };
            default = { };
            description = "Paseo web app settings. Requires a NixOS host with Caddy.";
          };
        };
      };
      default = { };
      description = "Paseo settings. Paseo is a self-hosted daemon for AI coding agents, accessible via web/CLI/mobile.";
    };
    herdr = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Cloudflare Zero Trust-protected web terminal for herdr (ttyd + herdr session attach default)";
          port = lib.mkOption {
            type = lib.types.port;
            default = 5955;
            description = "Port for ttyd web terminal serving herdr.";
          };
        };
      };
      default = { };
      description = "Herdr web terminal settings. Exposes herdr session attach default via ttyd at herdr.<domain> through Cloudflare Tunnel.";
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
    hermes = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "the sandboxed Hermes Agent deployment (Docker terminal backend, optional messaging gateway)";
          useNixImage = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Use a Nix-built (dockerTools) sandbox image as the Docker terminal backend image. When false, registryImage is used.";
          };
          registryImage = lib.mkOption {
            type = lib.types.str;
            default = "nikolaik/python-nodejs:python3.11-nodejs20";
            description = "Registry image used as the Docker sandbox when useNixImage is false.";
          };
          extraPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Extra packages baked into the Nix sandbox image (e.g. language toolchains). Only used when useNixImage is true.";
          };
          containerCpu = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = "CPU cores allotted to each sandbox container.";
          };
          containerMemory = lib.mkOption {
            type = lib.types.int;
            default = 6144;
            description = "Memory (MB) allotted to each sandbox container.";
          };
          containerDisk = lib.mkOption {
            type = lib.types.int;
            default = 51200;
            description = "Disk (MB) per sandbox container (only enforced on overlay2 + XFS pquota).";
          };
          gateway = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Run the Hermes messaging gateway (Discord, etc.) as a user service. Requires platform tokens and allowlists in ~/.hermes/.env.";
                };
              };
            };
            default = { };
            description = "Hermes messaging gateway settings.";
          };
        };
      };
      default = { };
      description = "Sandboxed Hermes Agent deployment: Docker terminal backend with per-repo profile sandboxes, a web dashboard, and an optional messaging gateway.";
    };
    maki = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "maki terminal AI coding agent config" // {
            default = true;
          };
          mem0 = {
            enable = lib.mkEnableOption "mem0 memory backend (Python venv + MCP server)" // {
              default = true;
            };
            llmModel = lib.mkOption {
              type = lib.types.str;
              default = "llama3.2";
              description = "Fact extraction model for mem0 (Ollama).";
            };
            embedModel = lib.mkOption {
              type = lib.types.str;
              default = "nomic-embed-text";
              description = "Embeddings model for mem0 (Ollama).";
            };
          };
          defaultModel = lib.mkOption {
            type = lib.types.str;
            default = "xiaomi/mimo-v2.5-pro";
            description = "Default model spec for maki-serve (format: provider/model-id).";
          };
          models = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  spec = lib.mkOption {
                    type = lib.types.str;
                    description = "Model spec (provider/model-id).";
                  };
                  name = lib.mkOption {
                    type = lib.types.str;
                    description = "Display name.";
                  };
                };
              }
            );
            default = [
              {
                spec = "xiaomi/mimo-v2.5-pro";
                name = "MiMo V2.5 Pro";
              }
              {
                spec = "xiaomi/mimo-v2.5";
                name = "MiMo V2.5";
              }
              {
                spec = "smortress/gemma-4-31b";
                name = "Gemma 4 31B (smortress)";
              }
            ];
            description = "Available models exposed via GET /api/models and shown in the web UI model dropdown.";
          };
          rtk = {
            enable = lib.mkEnableOption "rtk (bash output filter) in PATH" // {
              default = true;
            };
          };
          monty = {
            enable = lib.mkEnableOption "pydantic-monty (code execution sandbox) in PATH" // {
              default = true;
            };
          };
        };
      };
      default = { };
    };
    pi = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Pi coding agent (@earendil-works/pi-coding-agent)" // {
            default = false;
          };
          defaultProvider = lib.mkOption {
            type = lib.types.str;
            default = "xiaomi";
            description = "Default LLM provider for pi.";
          };
          defaultModel = lib.mkOption {
            type = lib.types.str;
            default = "xiaomi/mimo-v2.5-pro";
            description = "Default model for pi.";
          };
          defaultThinkingLevel = lib.mkOption {
            type = lib.types.str;
            default = "high";
            description = "Default thinking level for pi (none/low/medium/high).";
          };
          packages = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Pi packages to install via `pi install`.";
          };
          compaction = {
            reserveTokens = lib.mkOption {
              type = lib.types.int;
              default = 32768;
              description = "Token budget reserved for agent output after compaction.";
            };
            keepRecentTokens = lib.mkOption {
              type = lib.types.int;
              default = 48000;
              description = "Number of recent tokens preserved during compaction.";
            };
          };
          fishAbbrs = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Register fish abbreviations for pi commands.";
          };
        };
      };
      default = { };
      description = "Pi coding agent settings.";
    };
    piDashboard = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "pi-agent-dashboard systemd user service" // {
            default = false;
          };
          port = lib.mkOption {
            type = lib.types.int;
            default = 12321;
            description = "Port for the pi-agent-dashboard server.";
          };
        };
      };
      default = { };
      description = "Pi agent dashboard settings (pi.sammohr.dev).";
    };
    tau = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Tau web UI (mirrors OMP session in browser)" // {
            default = false;
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 3001;
            description = "Port for the Tau mirror server.";
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Bind address for the Tau server. Only 127.0.0.1 needed since cloudflared tunnels localhost.";
          };
          user = lib.mkOption {
            type = lib.types.str;
            default = "smores";
            description = "HTTP Basic Auth username for Tau.";
          };
          passwordFile = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Path to file containing the HTTP Basic Auth password for Tau. Empty = no auth. Managed by oh-my-pi activation when set.";
          };
        };
      };
      default = { };
      description = "Tau web UI mirror for OMP sessions.";
    };
    agentOfEmpires = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Agent of Empires session manager" // {
            default = false;
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8080;
            description = "Port for the AoE web dashboard.";
          };
        };
      };
      default = { };
      description = "Agent of Empires multi-agent session manager.";
    };
    aiHints = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "AI coding assistant context/rules, shared across pi and opencode.";
    };
    goose = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "goose AI agent (CLI + MiMo & DeepSeek providers)" // {
            default = true;
          };
          server = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkEnableOption "goosed agent server (systemd user service)" // {
                  default = false;
                };
              };
            };
            default = { };
          };
          web = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkEnableOption "goose-web PWA" // {
                  default = false;
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  default = 2999;
                };
              };
            };
            default = { };
          };
        };
      };
      default = { };
      description = "Goose AI agent settings.";
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
        {
          assertion =
            config.dotfiles.opencodeHost.bindAddress == null
            || config.dotfiles.opencodeHost.opencodePort != config.dotfiles.opencodeHost.openchamberPort;
          message = "opencodeHost opencodePort and openchamberPort must be different";
        }
      ];

    dotfiles = {
      wayland = config.dotfiles.displayManager == "niri";
      terminal = "kitty";
      shell = "fish";
      browser = "firefox";
      font = "CaskaydiaCove Nerd Font";
      fontPackage = pkgs.nerd-fonts.caskaydia-cove;
      shellPath = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
      defaultModel = "gemma-4-31b";
    };
  };
}
