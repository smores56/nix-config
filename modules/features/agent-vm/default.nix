# The Mac agent boundary (sdlc #427): `agent-sandbox claude` runs Claude in a headless Tart macOS
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
  # The rest are personal secrets and host-executed config. The guest gets its own .claude and
  # copies of the gh/gcloud/kube config below, so the host copies stay host-only.
  deny = [
    "Library"
    ".cache/Bitwarden"
    ".cache/cliphist"
    ".claude"
    ".config/Bitwarden"
    ".config/gh"
    ".config/gcloud"
    ".config/op"
    ".config/sops"
    ".config/ssh-sk"
    ".config/tutanota-desktop"
    ".docker"
    ".git-credentials"
    ".gnupg"
    ".kube"
    ".local/share/Bitwarden"
    ".local/share/memory"
    ".local/share/proton-pass-cli"
    ".local/state/harvest"
    ".local/state/key-backup"
    ".local/state/proton"
    ".local/state/syncthing"
    ".netrc"
    ".npmrc"
    ".op"
    ".pki"
    ".ssh/google_compute_engine"
    ".tart"
    ".Trash"
    ".zsh_history"
    ".bash_history"
    "Sync"
    "Vault"
  ];
  # Read-write; everything else shared is read-only. The host config that executes code on the
  # host (Claude hooks, gh aliases, kube exec, gcloud exec) is denied above and copied to the
  # guest-local tree below, so the guest cannot make the host run its config.
  rw = [
    "Blitzy"
    "repos"
    "dev"
    ".local/state/agent"
    ".cache/agent"
  ];
  # Absolute read-only shares mounted at the same path; the host store is always shared.
  extra = [ "/opt/homebrew" ];
  # Host CLI config copied into a guest-local tree each launch, with the env vars below pointing
  # at the copy. The host paths are denied, so this is the only copy the guest can see.
  guestConfig = [
    ".config/gh"
    ".config/gcloud"
    ".docker/config.json"
    ".kube"
  ];
  # sops secrets copied into the guest each launch so the agent can sign and push (the human's
  # choice on #427); the other secrets never leave the host.
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
      guestConfig
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
