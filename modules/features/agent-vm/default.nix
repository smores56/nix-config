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
  # Read-write; everything else shared is read-only. Each is also host-executed configuration
  # (Claude hooks, kubeconfig exec, gh aliases, repo .git/config), so a guest can reach host code
  # through them; that escape, and Docker Desktop's own File sharing, are accepted risks on #386.
  rw = [
    "Blitzy"
    "repos"
    ".claude"
    ".config/gcloud"
    ".kube"
    ".config/gh"
  ];
  # Absolute read-only shares mounted at the same path; the host store is always shared.
  extra = [ "/opt/homebrew" ];
  # sops secrets copied into the guest each launch so the agent can sign and push (the human's
  # choice on #386); the other secrets never leave the host.
  handIn = [
    "github-personal-pat"
    "github-personal-signing-key"
    "github-work-pat"
    "github-work-signing-key"
  ];

  substitutions = {
    vm = "agent-vm";
    # Pinned so a re-clone gets the image the hardening was written against.
    image = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:4aaa751fa7538902d73c767f27a066fc87e83f183069da4e4b5022863abd4c77";
    planner = "${../../lib/share_planner.py}";
    # The guest has no Docker.app, so its CLI comes from the shared store; the daemon is the
    # host Docker Desktop, reached through the per-session forwarded socket.
    guestPath = lib.makeBinPath [ pkgs.docker-client ];
    caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };
  arrays = {
    inherit
      deny
      rw
      extra
      handIn
      ;
  };

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
      let
        values =
          lib.mapAttrs (_: lib.escapeShellArg) substitutions // lib.mapAttrs (_: lib.escapeShellArgs) arrays;
      in
      builtins.replaceStrings (map (n: "@${n}@") (lib.attrNames values)) (lib.attrValues values) (
        builtins.readFile ./agent-vm.sh
      );
  };
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    home.packages = [ agentSandbox ];
    user.shellAbbrs.a = "agent-sandbox claude";
  };
}
