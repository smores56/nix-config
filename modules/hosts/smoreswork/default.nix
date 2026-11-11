# smoreswork: the employer's macOS laptop. Home-only (no NixOS config); its
# `system` drives the Darwin home build.
{
  system = "aarch64-darwin";
  username = "sam";
  home = true;

  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/darwin-work.nix
  ];
  homeModules = [
    ./sops.nix
    ./memory.nix
    ../../features/chat-proxy.nix
  ];
  homeOptions = {
    # #509 retirement: off keeps the Mac chat proxy until the cutover.
    kanbeiSplit.cutover.enable = false;
  };

  user.aiProfile = "work";
}
