# Niri desktop: terminal, GUI apps, and dictation.
{
  home = [
    ../features/terminal.nix
    ../desktop/niri/keybinds.nix
    ../desktop/niri/settings.nix
    ../desktop/niri/noctalia.nix
    ../desktop/linux-apps.nix
    ../features/dictation/default.nix
    ../features/wallpapers.nix
  ];
  nixos = [
    ../nixos/desktop.nix
    ../nixos/niri.nix
    ../nixos/fprintd.nix
  ];
}
