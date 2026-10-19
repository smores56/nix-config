# Employer macOS host: zsh, AeroSpace, work identity, OpenAI-only maki.
{
  home = [
    ../features/terminal.nix
    ../features/cargo.nix
    ../features/work-host.nix
    ../desktop/aerospace/default.nix
  ];
  nixos = [ ];
}
