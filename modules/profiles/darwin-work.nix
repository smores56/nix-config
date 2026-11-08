# Employer macOS host: zsh, AeroSpace, work identity.
{
  home = [
    ../features/terminal.nix
    ../features/brew.nix
    ../features/cargo.nix
    ../features/work-host.nix
    ../desktop/aerospace/default.nix
    ../desktop/macos-defaults.nix
    ../features/wallpapers.nix
    ../features/agent-vm
  ];
  nixos = [ ];
}
