# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  dotfiles = {
    displayManager = "niri";
    nixos = true;
    fingerprint = true;
    photobucket.enable = true;
  };
}
