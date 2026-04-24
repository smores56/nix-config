{ displayManager, ... }:
let
  displayManagerModules = {
    pop-os = [
      ./dconf.nix
      ./linux-apps.nix
    ];
    osx = [
      ./aerospace.nix
    ];
    niri = [
      ./niri.nix
      ./linux-apps.nix
    ];
  };
in
{
  imports =
    [ ./terminal-emulator ]
    ++ (displayManagerModules.${displayManager} or [ ]);
}
