# Differences between smoreswork (macOS) and smorespro (Linux) that are on purpose. Checked by
# tests/laptop_parity.nix: a difference not listed here fails, and so does an entry that no
# longer differs. Shape: category -> name -> "<inherent|work-policy>: reason".
{ lib }:
let
  group = reason: names: lib.genAttrs names (_: reason);
  merge = lib.foldl' (a: b: a // b) { };

  mac = "inherent: macOS-only";
  linux = "inherent: Linux desktop only; the Mac has no equivalent here";
  maki = "work-policy: Maki is not installed on the work host";
  memoryLocal = "work-policy: the Mac runs its own local memory instance; Linux uses smortress's";
  zsh = "inherent: the Mac's shell is zsh, Linux's is fish";
  brain = "work-policy: the brain vault lives on the work host only";
in
{
  shell = merge [
    {
      "abbrs.m" =
        "work-policy: unsandboxed `claude` on the Mac (Sam's choice, managed policy removed 2026-11-04); `agent-sandbox maki` on Linux";
      "abbrs.ms" = maki;
      "abbrs.ns" = "inherent: nixos-rebuild exists only on NixOS";
      "env.CC" = "inherent: macOS toolchain in /usr/bin";
      "env.CXX" = "inherent: macOS toolchain in /usr/bin";
      "env.TERMINFO_DIRS" = "inherent: macOS ships an older terminfo database";
      "env.BLITZY_REPOS_DIR" = "work-policy: employer checkouts live only on the work host";
      "env.LOCALE_ARCHIVE_2_27" = "inherent: glibc locale archive";
    }
    (group brain [ "env.BRAIN_DIR" ])
    (group linux [
      "env.SSH_ASKPASS"
      "env.SSH_ASKPASS_REQUIRE"
      "env.SSH_SK_HELPER"
      "env.XCURSOR_SIZE"
      "env.XCURSOR_THEME"
      "env.XDG_CONFIG_DIRS"
      "env.XDG_DATA_DIRS"
    ])
    (group "inherent: xdg.enable is on for the Linux desktop; macOS keeps tool defaults" [
      "env.XDG_BIN_HOME"
      "env.XDG_CACHE_HOME"
      "env.XDG_CONFIG_HOME"
      "env.XDG_DATA_HOME"
      "env.XDG_STATE_HOME"
    ])
    (group "inherent: fish-only settings; zsh has its own prompt and greeting" [
      "env.async_prompt_functions"
      "env.fish_greeting"
      "env.fish_terminal_skip_dsr"
    ])
  ];

  ssh = group "inherent: sockets live under ~/.ssh on macOS and $XDG_RUNTIME_DIR on Linux" [
    "*.ControlPath"
    "smortress.ForwardAgent"
    "smortress.IdentityAgent"
    "tang-pi.IdentityAgent"
  ];

  packages = merge [
    (group mac [
      "aerospace-layout"
      "apple-sdk"
      "libiconv"
    ])
    (group "inherent: kitty comes from a brew cask on the Mac (its nix build is rejected by launchd)" [
      "kitty"
    ])
    (group zsh [
      "zsh"
      "nix-zsh-completions"
      "fish"
      "hm-session-vars.fish"
      "man-db"
    ])
    (group maki [
      "agent-sandbox"
      "agent-sandbox-check"
      "maki-session-resume"
      "maki-session-search"
      "rtk"
    ])
    (group memoryLocal [
      "memory"
      "memory-mcp"
    ])
    (group brain [ "brain-run" ])
    (group linux [
      "bibata-cursors"
      "bitwarden-desktop"
      "bitwarden-menu"
      "brightnessctl"
      "concord"
      "discord"
      "dolphin"
      "dummy-xdg-mime-dirs1"
      "dummy-xdg-mime-dirs2"
      "evince"
      "feh"
      "firefox"
      "gimp"
      "grim"
      "index.theme"
      "krita"
      "noctalia"
      "playerctl"
      "shared-mime-info"
      "slurp"
      "ssh-askpass"
      "steam"
      "stylix-kde-theme"
      "transmission"
      "tutanota-desktop"
      "vlc"
      "voxtype"
      "wl-clipboard"
      "wtype"
    ])
  ];

  services = merge [
    (group "inherent: AeroSpace is a brew cask on the Mac; niri and its shell are Linux-only" [
      "aerospace"
    ])
    (group linux [
      "noctalia"
      "voxtype"
    ])
    (group "inherent: the Linux sudo/login agent is fido2-agent; the Mac's is sudo-agent" [
      "fido2-agent"
      "fido2-agent-load"
      "sudo-agent"
    ])
    (group mac [
      "piv-pin-wipe"
      "sops-nix"
    ])
    (group brain [ "brain-autopilot" ])
    (group memoryLocal [
      "memory-export"
      "memory-falkordb"
      "memory-graphiti-mcp"
      "memory-llm-proxy"
      "memory-mcp"
      "cloudflared-llm"
      "cloudflared-memory"
    ])
  ];

  activation = merge [
    (group mac [
      "checkAppManagementPermission"
      "configureScreenshotKeys"
      "copyApps"
      "setDarwinDefaults"
      "setupLaunchAgents"
      "sops-nix"
    ])
    (group linux [
      "reloadSystemd"
      "stylixLookAndFeel"
    ])
  ];
}
