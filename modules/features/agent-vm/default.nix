# The Mac agent boundary (sdlc #427): `agent-sandbox claude` runs Claude in a headless Tart macOS
# guest that sees only the `allowRw` tree at identical paths, so it has no host USB (YubiKey), host
# GUI dialogs or host sockets. T9 makes plain `claude` the `a` default on smoreswork.
{
  lib,
  pkgs,
  ...
}:
let
  # The allowlist is the control: nothing outside these trees is visible in the guest. Claude's
  # session state is shared so the host and the guest resume each other's conversations; its
  # config (~/.claude.json, settings.json, skills, agents, plugins, commands, CLAUDE.md) stays
  # host-only, and the guest keeps its own login and settings.
  allow = [ ];
  allowRw = [
    "Blitzy"
    "repos"
    # Working tree only; the book queue that used to live in `wip/books` is gone (#635).
    "wip"
    ".claude/file-history"
    ".claude/plans"
    ".claude/projects"
    ".claude/tasks"
  ];
  # Host CLI config copied into a guest-local tree each launch, with the env vars below pointing
  # at the copy. Those host paths are not visible in the guest, so the guest can write its own
  # config without touching the host.
  guestConfig = [
    ".config/gh"
    ".config/gcloud"
    ".config/git"
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
      allow
      allowRw
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
    # T9: the work host runs plain Claude; the Tart sandbox is opt-in, not the `a` alias.
    user.shellAbbrs.a = "claude";
  };
}
