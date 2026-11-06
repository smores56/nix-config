# The Mac agent boundary (sdlc #386): `agent-sandbox claude` runs Claude in a headless Tart macOS
# guest that sees $HOME at identical paths minus `deny`, so it has no host USB (YubiKey), host GUI
# dialogs or host sockets. Plain `claude` on the host stays the deliberate opt-out.
{
  lib,
  pkgs,
  ...
}:
let
  # Never shared: browser/app data and Keychains live in ~/Library; .tart holds the VM's own disk;
  # .Trash is TCC-protected and Virtualization.framework refuses the whole config over it.
  deny = [
    "Library"
    ".config/sops"
    ".tart"
    ".Trash"
  ];
  # Read-write; everything else shared is read-only. These are host-executed configs too (Claude
  # hooks, kubeconfig exec, gh aliases, repo .git/config) — an accepted risk recorded on #386.
  rw = [
    "Blitzy"
    "repos"
    ".claude"
    ".config/gcloud"
    ".kube"
    ".config/gh"
  ];
  # The guest has no Docker.app, so its CLI comes from the shared store; the daemon is the
  # host Docker Desktop, reached through the per-session forwarded socket.
  guestPath = lib.makeBinPath [ pkgs.docker-client ];

  # Absolute read-only shares; the first is the host store, mounted at /nix/store in the guest.
  extra = [
    "/nix/store"
    "/opt/homebrew"
  ];

  agentSandbox = pkgs.writeShellApplication {
    name = "agent-sandbox";
    runtimeInputs = [
      pkgs.tart
      pkgs.jq
      pkgs.python3
      pkgs.openssh
      pkgs.coreutils
    ];
    text =
      builtins.replaceStrings
        [
          "@VM@"
          "@IMAGE@"
          "@PLANNER@"
          "@GUEST_PATH@"
          "@DENY@"
          "@RW@"
          "@EXTRA@"
        ]
        (
          map lib.escapeShellArg [
            "agent-vm"
            "ghcr.io/cirruslabs/macos-tahoe-base:latest"
            "${../../lib/share_planner.py}"
          ]
          ++ [ (lib.escapeShellArg guestPath) ]
          ++ map (l: lib.escapeShellArg (lib.concatStringsSep " " l)) [
            deny
            rw
            extra
          ]
        )
        (builtins.readFile ./agent-vm.sh);
  };
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    home.packages = [ agentSandbox ];
    user.shellAbbrs.a = "agent-sandbox claude";
  };
}
