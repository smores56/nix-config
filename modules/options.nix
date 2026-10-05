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
    aiProfile = lib.mkOption {
      type = lib.types.enum [
        "personal"
        "work"
      ];
      default = "personal";
      description = "Which model providers coding agents may use. 'work' keeps agents on Anthropic only, so work code never reaches personal providers.";
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
    searchPort = lib.mkOption {
      type = lib.types.port;
      default = 8899;
      description = "TCP port the self-hosted SearXNG listens on. Single source of truth: the NixOS service and the templated maki websearch plugin both derive from it.";
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
          tunnelName = lib.mkOption {
            type = lib.types.str;
            default = "smortress";
            description = "Stable human label for the tunnel. NOT the UUID: cloudflared resolves the real UUID from credentialsFile at runtime, and the reconciler reads it back out of that file. Empty leaves the tunnel daemon off.";
          };
          credentialsFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/cloudflared/credentials.json";
            description = "Path to the tunnel credentials JSON on the host. Kept out of the Nix store; provisioned out-of-band.";
          };
          apiTokenFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/cloudflare/api-token";
            description = "Path to the scoped Cloudflare API token (Zone:DNS:Write + Access: Apps and Policies:Write) on the host, mode 0600. Read by the reconciler at runtime; never enters the Nix store.";
          };
          services = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  port = lib.mkOption {
                    type = lib.types.port;
                    description = "Loopback port the service listens on.";
                  };
                  access.enable = lib.mkEnableOption "Cloudflare Access in front of this endpoint (account IdP, shared allow-list)";
                };
              }
            );
            default = { };
            description = "Services to expose, keyed by subdomain: each becomes <sub>.<domain> -> http://127.0.0.1:<port>, with a proxied DNS CNAME to the tunnel reconciled on every activation.";
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
    photobucket = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "photobucket feh-based photo triage reviewer";
          root = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Root for photobucket decision logs and bucket folders. Empty means ~/Pictures/_triage.";
          };
        };
      };
      default = { };
      description = "Keyboard-driven photo triage reviewer built on feh.";
    };

    immich = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "self-hosted Immich photo library (NixOS-only)";
          mediaLocation = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/immich";
            description = "Directory Immich stores its managed library in. The default is created by the Immich module.";
          };
          backup = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkEnableOption "daily Immich backup (restic snapshots + offsite copy)";
                protonRemote = lib.mkOption {
                  type = lib.types.str;
                  default = "proton";
                  description = "rclone remote name for the offsite mirror.";
                };
                protonPath = lib.mkOption {
                  type = lib.types.str;
                  default = "immich/restic";
                  description = "Folder inside the remote holding the restic repo.";
                };
                rcloneConfig = lib.mkOption {
                  type = lib.types.path;
                  default = "/var/lib/immich/rclone.conf";
                  description = "rclone config with the Proton remote (mode 600, owned by immich).";
                };
                schedule = lib.mkOption {
                  type = lib.types.str;
                  default = "daily";
                  description = "systemd OnCalendar expression for the backup timer.";
                };
              };
            };
            default = { };
            description = "Backup of the Immich library and database into the local backup disk, mirrored offsite.";
          };
        };
      };
      default = { };
      description = "Self-hosted Immich photo/video library and its Postgres/Redis backing services.";
    };

    backup = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "the local backup disk (versioned snapshot target)";
          mountPoint = lib.mkOption {
            type = lib.types.path;
            default = "/var/backup";
            description = "Where the backup disk is mounted. Tenants get their own folder beneath it.";
          };
          device = lib.mkOption {
            type = lib.types.str;
            default = "/dev/disk/by-label/backup";
            description = "Block device or by-label/by-uuid path of the backup disk.";
          };
          rcloneConfig = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/backup/rclone.conf";
            description = "rclone config holding the offsite remote (mode 0600, owned by root). Read at runtime; never placed in the Nix store.";
          };
          remote = lib.mkOption {
            type = lib.types.str;
            default = "proton";
            description = "rclone remote name for offsite mirrors, e.g. \"proton\".";
          };
          datasets = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  source = lib.mkOption {
                    type = lib.types.nullOr lib.types.path;
                    default = null;
                    description = "Directory to back up. Defaults to /var/lib/media/<Name>.";
                  };
                  offsite = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Mirror the local copy to the remote (append-only).";
                  };
                  preBackup = lib.mkOption {
                    type = lib.types.nullOr lib.types.lines;
                    default = null;
                    description = "Shell snippet run before the copy. Its env exposes BACKUP_DATE, BACKUP_CURRENT, BACKUP_SOURCE.";
                  };
                  excludes = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = "rclone exclude patterns kept out of both mirrors (secrets, regenerable caches).";
                  };
                  schedule = lib.mkOption {
                    type = lib.types.str;
                    default = "daily";
                    description = "systemd OnCalendar expression for the backup timer.";
                  };
                  timeout = lib.mkOption {
                    type = lib.types.str;
                    default = "12h";
                    description = "systemd TimeSpan cap on a run (TimeoutStartSec). Generous for the first seed run; shorten later.";
                  };
                  stallTimeout = lib.mkOption {
                    type = lib.types.str;
                    default = "30m";
                    description = "Abort and retry a transfer that makes no progress for this long (a wedged Proton upload never trips rclone's own timeout). Copy is resumable, so retrying is safe. \"0\" disables.";
                  };
                };
              }
            );
            default = { };
            description = "Datasets backed up onto the disk by the generic rclone 3-2-1 mechanism.";
          };
        };
      };
      default = { };
      description = "Generic local backup disk; hosts mount it and backup features write beneath it.";
    };
    notify = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "service-failure push notifications via a self-hosted ntfy server";
          ntfyPort = lib.mkOption {
            type = lib.types.port;
            default = 2586;
            description = "Loopback port the local ntfy server listens on; the alert handler publishes here.";
          };
          topicFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/ntfy-alert/topic";
            description = "Path to the generated-once ntfy topic. Kept out of the Nix store; the handler reads it at runtime.";
          };
          # Resolved: the handler template's unit name, so watchers reference it
          # instead of hardcoding the string.
          unit = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            description = "Reference watchers put in `onFailure` to trigger the failure-alert handler (the template instantiation string, `notify@%n.service`).";
          };
        };
      };
      default = { };
      description = "Push notifications when a watched systemd unit fails, delivered through ntfy.";
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
    work = lib.mkOption {
      type = lib.types.submodule {
        options = {
          email = lib.mkOption {
            type = lib.types.str;
            description = "Commit email in work repos.";
          };
          githubOwnerGlob = lib.mkOption {
            type = lib.types.str;
            description = "GitHub owner pattern (git wildmatch, matched case-insensitively) whose repos use the work identity.";
          };
          branchPrefix = lib.mkOption {
            type = lib.types.str;
            description = "Branch prefix in work repos.";
          };
          sshKey = lib.mkOption {
            type = lib.types.str;
            description = "Work SSH key (private half; the .pub is used for auth and signing via the agent).";
          };
          sshConfig = lib.mkOption {
            type = lib.types.str;
            description = "Standalone ssh config that work-repo git uses instead of ~/.ssh/config.";
          };
          flow = lib.mkOption {
            type = lib.types.enum [
              "direct"
              "pr"
            ];
            description = "How changes land: 'direct' merges to main, 'pr' goes through pull requests.";
          };
        };
      };
      readOnly = true;
      description = "Work identity, applied per repo by remote URL on every host.";
    };
    githubUser = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Personal GitHub account; repos it owns use the direct-to-main flow.";
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
      work = {
        email = "smohr@blitzy.com";
        githubOwnerGlob = "blitzy-*";
        branchPrefix = "smohr";
        sshKey = "~/.ssh/id_work";
        sshConfig = "~/.ssh/config.work";
        flow = "pr";
      };
      githubUser = "smores56";
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
      notify.unit = "notify@%n.service";
    };
  };
}
