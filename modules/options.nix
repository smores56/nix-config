{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config) machine user;

  homeDirectory =
    if lib.hasSuffix "-darwin" machine.system then
      "/Users/${machine.username}"
    else
      "/home/${machine.username}";

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
in
{
  options.machine = {
    system = lib.mkOption {
      type = lib.types.enum [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      default = "x86_64-linux";
      description = "Platform this host evaluates for.";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = "smores";
      description = "Primary local username for personal host-level configuration.";
    };
    nixos = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host is NixOS (as opposed to a user-managed OS such as macOS).";
    };
    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Profile names composed into this host; set from modules/hosts/<host>/default.nix.";
    };
    graphical = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Host runs a graphical session (a desktop or work profile is composed in).";
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Host runs the Niri Wayland desktop.";
    };
    workHost = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Host composes the work profile.";
    };
  };

  options.user = {
    email = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Default git identity.";
    };
    sshKey = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Personal SSH key path without extension; its `.pub` is fetched from Proton Pass and offered via the agent, which holds the private half.";
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
            description = "Work SSH key path without extension; its `.pub` is fetched from Proton Pass and offered via the agent, which holds the private half.";
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
    shell = lib.mkOption {
      type = lib.types.enum [
        "fish"
        "zsh"
      ];
      readOnly = true;
      description = "Interactive and login shell: zsh on work hosts (the employer's tooling and docs assume it), fish everywhere else.";
    };
    font = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    fontPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
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
      description = "Second-brain vault directory, relative to home, maintained by the `brain` skill. When set, `BRAIN_DIR` is exported, assistant context points sessions at it, `brain-run` is installed, and on macOS a weekday 17:30 launchd job runs an unattended, paid `claude -p` harvest (up to $10 a run; see modules/features/ai/brain/); null leaves the vault unconfigured.";
    };
  };

  config = {
    machine = {
      graphical =
        builtins.elem "linux-desktop" machine.profiles || builtins.elem "darwin-work" machine.profiles;
      wayland = builtins.elem "linux-desktop" machine.profiles;
      workHost = builtins.elem "darwin-work" machine.profiles;
    };

    user = {
      email = "sam@sammohr.dev";
      sshKey = "~/.ssh/id_personal";
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
          dir = "${homeDirectory}/Blitzy";
          envVar = "BLITZY_REPOS_DIR";
        };
        sshKey = "~/.ssh/id_work";
        sshConfig = "~/.ssh/config.work";
        flow = "pr";
      };
      githubUser = "smores56";
      codeRoot = "${homeDirectory}/code";
      shell = if machine.workHost then "zsh" else "fish";
      font = "Google Sans Code";
      fontPackage = pkgs.googlesans-code;
    };

    assertions = [
      {
        assertion =
          !(builtins.elem "server" machine.profiles)
          || !(
            builtins.elem "linux-desktop" machine.profiles || builtins.elem "darwin-work" machine.profiles
          );
        message = "the server profile cannot be combined with a graphical or work profile";
      }
    ];
  };
}
