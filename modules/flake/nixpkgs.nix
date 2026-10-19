{ inputs, lib, ... }:
let
  nixpkgsFor =
    system: if lib.hasSuffix "-darwin" system then inputs.nixpkgs-darwin else inputs.nixpkgs;
in
{
  # The one place that picks a nixpkgs per system for homes and checks, so a
  # platform never mixes package sets. Lint and the formatter deliberately
  # stay on `nixpkgs` so nixfmt matches across platforms.
  _module.args.nixpkgsFor = nixpkgsFor;

  # The one package-set constructor: every evaluated set shares the same
  # unfree policy. Lint and the formatter use raw `inputs.nixpkgs` on purpose.
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
