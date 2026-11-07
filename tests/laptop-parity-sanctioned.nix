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
  harvest = "work-policy: the work-trail harvest into the Mac's memory runs on the work host only";
  todo = "inherent: todo.txt sync is part of the Linux desktop; the Mac's Syncthing is a root LaunchDaemon, so a human-editable folder needs a second identity";
in
{
  shell = merge [
    {
      "abbrs.a" =
        "inherent: the agent differs per host (`agent-sandbox claude` in the Tart VM on the Mac, `agent-sandbox maki` on Linux)";
      "abbrs.ms" = maki;
      "abbrs.mp" = maki;
      "abbrs.ns" = "inherent: nixos-rebuild exists only on NixOS";
      "env.CC" = "inherent: macOS toolchain in /usr/bin";
      "env.CXX" = "inherent: macOS toolchain in /usr/bin";
      "env.TERMINFO_DIRS" = "inherent: macOS ships an older terminfo database";
      "env.BLITZY_REPOS_DIR" = "work-policy: employer checkouts live only on the work host";
      "env.LOCALE_ARCHIVE_2_27" = "inherent: glibc locale archive";
    }
    (group "inherent: NymVPN runs only on the NixOS laptop; the Mac has no daemon to control" [
      "abbrs.nv"
      "abbrs.nvc"
      "abbrs.nvd"
    ])
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

  ssh =
    group
      "inherent: ControlPath is ~/.cache/ssh-%C on the Mac (short, for its 104-byte socket limit) and under $XDG_RUNTIME_DIR on Linux; the agent sockets live in ~/.ssh on the Mac and $XDG_RUNTIME_DIR on Linux"
      [
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
      "agent-vm-check"
      "maki-private"
      "maki-session-resume"
      "maki-session-search"
      "rtk"
    ])
    (group memoryLocal [
      "memory"
      "memory-mcp"
    ])
    (group todo [
      "syncthing"
      "todo.txt-cli"
    ])
    (group harvest [ "harvest" ])
    (group "inherent: steam is a brew cask on the Mac" [ "steam" ])
    (group "inherent: Linux runs the free Brave Origin nix package; the Mac uses the Brave brew cask" [
      "brave-origin"
    ])
    (group "work-policy: personal desktop apps stay off the employer laptop" [
      "bitwarden-desktop"
      "discord"
      "gimp"
      "krita"
      "transmission"
      "tutanota-desktop"
      "vlc"
    ])
    (group linux [
      "bibata-cursors"
      "bitwarden-menu"
      "brightnessctl"
      "concord"
      "dolphin"
      "dummy-xdg-mime-dirs1"
      "dummy-xdg-mime-dirs2"
      "evince"
      "feh"
      "grim"
      "index.theme"
      "noctalia"
      "playerctl"
      "shared-mime-info"
      "slurp"
      "ssh-askpass"
      "stylix-kde-theme"
      "voxtype"
      "wl-clipboard"
      "wtype"
    ])
  ];

  services = merge [
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
    (group harvest [ "harvest" ])
    (group todo [
      "syncthing"
      "syncthing-init"
    ])
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

  programs = {
    aerospace = "inherent: the Mac's window manager (a brew cask); Linux runs niri";
    inherit zsh;
    fish = zsh;
    noctalia = linux;
  };

  activation = merge [
    { "todoFiles" = todo; }
    (group mac [
      "checkAppManagementPermission"
      "configureSystemHotkeys"
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
