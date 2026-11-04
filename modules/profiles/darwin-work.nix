# Employer macOS host: zsh, AeroSpace, work identity.
{
  home = [
    ../features/terminal.nix
    ../features/cargo.nix
    ../features/work-host.nix
    ../features/ai/claude-policy.nix
    ../desktop/aerospace/default.nix
    ../desktop/macos-defaults.nix
    ../features/wallpapers.nix
  ];
  nixos = [ ];
}
