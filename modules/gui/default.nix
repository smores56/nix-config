{ displayManager, ... }:
{
  fonts.fontconfig.enable = true;

  imports = [
    ./terminal-emulator
  ]
  ++ (
    if displayManager == "pop-os" then
      [
        ./dconf.nix
        ./linux-apps.nix
      ]
    else if displayManager == "osx" then
      [
        ./aerospace.nix
      ]
    else if displayManager == "niri" then
      [
        ./niri.nix
        ./linux-apps.nix
      ]
    else
      [ ]
  );
}
