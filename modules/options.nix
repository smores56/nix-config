{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) smortress;
  ports = import ./ports.nix;
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

  # How `worktrees new` names branches; rendered into git config so the
  # owner's include picks the scheme per repo.
  branchNamingType = lib.types.submodule {
    options = {
      template = lib.mkOption {
        type = lib.types.str;
        description = "Branch name template with {slug}, {ticket} (a ticket key such as ABC-123) and {type} (fix, feat, …) placeholders.";
      };
      unticketed = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Template used when `template` needs {ticket} and no ticket was given; null makes a ticket required.";
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
      description = "Which model providers Maki may use. 'work' keeps Maki on OpenAI only, without the personal providers.";
    };
    shellAbbrs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Abbreviations for whichever shell the host uses, each one string both fish and zsh accept. `pick <tv-channel> <command…>` runs a picker, then the command with the selection appended (or in place of {name}, its basename).";
    };
    brain.dir = lib.mkOption {
      # Relative, no leading or trailing slash: joined onto the home directory.
      type = lib.types.nullOr (lib.types.strMatching "[^/].*[^/]|[^/]");
      default = null;
      example = "brain";
      description = "Second-brain vault directory, relative to home, maintained by the `brain` skill. When set, `BRAIN_DIR` is exported and assistant context points sessions at it; null leaves the vault unconfigured.";
    };
    workHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "This host does day-to-day work development: its shell is zsh (`dotfiles.shell`), sourcing the tooling-owned ~/.zshrc, and when `dotfiles.work.flatRepos` is set it gets that repo layout. Independent of `aiProfile`.";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = "smores";
      description = "Primary local username for personal host-level configuration.";
    };
    exposeSsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host runs sshd, bound to loopback so it is reachable only through the Cloudflare Tunnel (cloudflared dials 127.0.0.1:22). Also disables sudo password prompts for wheel.";
    };
    sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... sam@example.com" ];
      description = "Public keys sshd accepts on hosts with dotfiles.exposeSsh. Only the public half ever reaches a server; the private keys stay in Proton Pass.";
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
      default = ports.searx;
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
            description = "Path to the tunnel credentials JSON on the host. Kept out of the Nix store; provisioned out-of-band, except on smortress which points this at its sops-decrypted copy.";
          };
          apiTokenFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/cloudflare/api-token";
            description = "Path to the scoped Cloudflare API token (Zone:DNS:Write + Access: Apps and Policies:Write) on the host, mode 0600. Read by the reconciler at runtime; never enters the Nix store. smortress points this at its sops-decrypted copy.";
          };
          services = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  port = lib.mkOption {
                    type = lib.types.port;
                    description = "Loopback port the service listens on.";
                  };
                  protocol = lib.mkOption {
                    type = lib.types.enum [
                      "http"
                      "tcp"
                      "ssh"
                    ];
                    default = "http";
                    description = "Origin scheme cloudflared proxies to. Non-HTTP schemes (tcp/ssh) are reached from clients via `cloudflared access <tcp|ssh>`, not a browser.";
                  };
                  access = {
                    enable = lib.mkEnableOption "Cloudflare Access in front of this endpoint (account IdP, shared allow-list)";
                    serviceAuth = lib.mkEnableOption ''
                      an additional Cloudflare Access Service Auth policy accepting any valid account service token. Set it for endpoints unattended clients reach (cloudflared access ssh/tcp) so they authenticate with a token minted in the dashboard instead of an IdP browser login; the email allow-list policy stays as a human fallback
                    '';
                  };
                };
              }
            );
            default = { };
            description = "Services to expose, keyed by subdomain: each becomes <sub>.<domain> -> <protocol>://127.0.0.1:<port>, with a proxied DNS CNAME to the tunnel reconciled on every activation.";
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
          passwordFile = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "File holding the OPDS account password. Empty falls back to ~/.config/calibre-server/password; smortress points this at its sops-decrypted copy.";
          };
        };
      };
      default = { };
      description = "calibre OPDS content server exposed over the Cloudflare Tunnel.";
    };
    chat = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Open WebUI chat front end (NixOS-only)";
          port = lib.mkOption {
            type = lib.types.port;
            default = ports.chat;
            description = "Loopback port for Open WebUI. Single-sourced from modules/ports.nix so the listener and the tunnel ingress cannot drift.";
          };
          jupyterPort = lib.mkOption {
            type = lib.types.port;
            default = ports.jupyter;
            description = "Loopback port for the code-interpreter Jupyter sandbox. Never exposed; reachable only by Open WebUI.";
          };
        };
      };
      default = { };
      description = "Self-hosted Open WebUI chat, exposed over the Cloudflare Tunnel.";
    };
    navidrome = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Navidrome music server (NixOS-only)";
          port = lib.mkOption {
            type = lib.types.port;
            default = 4533;
            description = "Loopback port for Navidrome.";
          };
          musicFolder = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/media/Music";
            description = "Music library Navidrome scans; the nixpkgs module mounts it read-only into the service.";
          };
          environmentFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/navidrome/env";
            description = "Root-owned ND_* secrets file read by systemd; carries ND_DEVAUTOCREATEADMINPASSWORD so the admin exists before the endpoint is public. Never in the Nix store; smortress points this at its sops-decrypted copy.";
          };
        };
      };
      default = { };
      description = "Self-hosted Navidrome music server, reading the media library read-only.";
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
          lanSources = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}");
            default = [ ];
            example = [ "10.0.0.0/24" ];
            description = "IPv4 source CIDRs allowed to reach the Immich port directly (the mobile app's local-network URL). Empty keeps Immich tunnel-only. Source-scoped rather than interface-scoped so a global-IPv6 uplink cannot expose it to the WAN. Each entry is interpolated into a root iptables command, so the type validates it as a CIDR.";
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
                  postgres = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Whether preBackup dumps PostgreSQL: puts the server's package on the unit PATH and orders the unit after postgresql.service.";
                  };
                  excludes = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    # `/.cache/**` is root-anchored and `**/.cache/**` is not
                    # (rclone's `**/` needs a preceding path segment), so a
                    # `.cache` at the source root needs the first pattern and
                    # a nested one the second; both are required.
                    default = [
                      "/.cache/**"
                      "**/.cache/**"
                      "/rclone.conf"
                    ];
                    description = "rclone exclude patterns kept out of both mirrors. Defaults to dropping regenerable caches at the source root and nested, plus a source-root rclone.conf copy; a credential-shaped file elsewhere in the tree is still copied unless you add it here.";
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
                  fullCheckSchedule = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional systemd OnCalendar for an extra whole-mirror integrity check: runs the same dataset with --full-check so drift in old, unchanged files is still caught. null (the default) disables it; the normal schedule verifies only the files that changed.";
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
    githubBackup = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "mirroring this host's GitHub repos onto the backup disk";
          tokenFile = lib.mkOption {
            # str, not path: a path interpolated into a derivation is copied into
            # the Nix store, which would publish the token.
            type = lib.types.str;
            default = "/run/secrets/github-repo-pat";
            description = "Runtime file holding a GitHub token with `repo` scope, read by ghorg; never placed in the Nix store.";
          };
          probeRepo = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "A known-private repo name. When set, the run fails unless that repo's mirror exists, catching a token without `repo` scope (private repos would otherwise be silently absent while the run still 'succeeds').";
          };
          schedule = lib.mkOption {
            type = lib.types.str;
            default = "*-*-* 00:30:00";
            description = "systemd OnCalendar for the mirror timer. Keep it ahead of the media datasets so the shared host lock never contends.";
          };
          timeout = lib.mkOption {
            type = lib.types.str;
            default = "6h";
            description = "systemd TimeSpan cap on a run; generous for a cold clone of every repo.";
          };
        };
      };
      default = { };
      description = "Mirror this host's GitHub repos onto the backup disk via ghorg (local-only; GitHub is the offsite copy).";
    };
    notify = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "service-failure push notifications via a self-hosted ntfy server";
          ntfyPort = lib.mkOption {
            type = lib.types.port;
            default = ports.ntfy;
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
    branchNaming = lib.mkOption {
      type = branchNamingType;
      readOnly = true;
      description = "Branch naming in every repo the work identity doesn't claim.";
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
          branchNaming = lib.mkOption {
            type = branchNamingType;
            description = "Branch naming in work repos.";
          };
          sshKey = lib.mkOption {
            type = lib.types.str;
            description = "Work SSH key path without extension; its `.pub` is materialised on disk and offered via the Proton Pass agent, which holds the private half.";
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
          flatRepos = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options = {
                  dir = lib.mkOption {
                    # Absolute, no trailing slash: it becomes link targets.
                    type = lib.types.strMatching "/.*[^/]";
                    description = "Absolute directory holding every work checkout flat as <dir>/<repo>, the layout the employer's tooling expects.";
                  };
                  envVar = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Environment variable the employer's tooling reads for `dir`; exported on work hosts.";
                  };
                };
              }
            );
            default = null;
            description = "Flat checkout layout for work hosts; null keeps work repos under codeRoot like any other.";
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
      type = lib.types.enum [
        "fish"
        "zsh"
      ];
      readOnly = true;
      description = "Interactive and login shell: zsh on work hosts (the employer's tooling and docs assume it), fish everywhere else.";
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
      # The vault's shared personal identity (design D6). Servers only ever
      # hold the public half; clients get the private half over SSH_AUTH_SOCK.
      sshAuthorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEu3DfhswY9f9hum/0OhAw2833CkZOP6wVKW5yJk6GpU sam@sammohr.dev"
      ];
      branchNaming.template = "smores/{slug}";
      work = {
        email = "smohr@blitzy.com";
        githubOwnerGlob = "blitzy-*";
        # Team convention: ticket first, else the change type.
        branchNaming = {
          template = "{ticket}-{slug}";
          unticketed = "{type}/{slug}";
        };
        flatRepos = {
          dir = "${config.home.homeDirectory}/Blitzy";
          envVar = "BLITZY_REPOS_DIR";
        };
        sshKey = "~/.ssh/id_work";
        sshConfig = "~/.ssh/config.work";
        flow = "pr";
      };
      githubUser = "smores56";
      codeRoot = "${config.home.homeDirectory}/code";
      terminal = "kitty";
      shell = if config.dotfiles.workHost then "zsh" else "fish";
      browser = "firefox";
      font = "Google Sans Code";
      fontPackage = pkgs.googlesans-code;
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
