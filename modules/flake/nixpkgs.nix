{ inputs, lib, ... }:
let
  nixpkgsFor =
    system: if lib.hasSuffix "-darwin" system then inputs.nixpkgs-darwin else inputs.nixpkgs;
in
{
  # The one package-set constructor: a nixpkgs per system with one unfree policy. Lint and the
  # formatter use raw `inputs.nixpkgs` so nixfmt matches across platforms.
  _module.args.mkPkgs =
    system: extra:
    import (nixpkgsFor system) (
      {
        inherit system;
        config.allowUnfree = true;
      }
      // extra
    );
}
