{ lib, ... }:
{
  options.dotfiles = {
    displayManager = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "niri"
      ]);
      default = null;
    };
    exposeSsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
}
