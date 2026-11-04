{ inputs, lib, ... }:
let
  nixpkgsFor =
    system: if lib.hasSuffix "-darwin" system then inputs.nixpkgs-darwin else inputs.nixpkgs;
in
{
  # The one package-set constructor: it picks a nixpkgs per system for homes
  # and checks, so a platform never mixes package sets, and every evaluated set
  # shares the same unfree policy. Lint and the formatter use raw
  # `inputs.nixpkgs` on purpose, so nixfmt matches across platforms.
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
