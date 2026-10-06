{ inputs, lib, ... }:
{
  # The one place that picks a nixpkgs per system for homes and checks, so a
  # platform never mixes package sets. Lint and the formatter deliberately
  # stay on `nixpkgs` so nixfmt matches across platforms.
  _module.args.nixpkgsFor =
    system: if lib.hasSuffix "-darwin" system then inputs.nixpkgs-darwin else inputs.nixpkgs;
}
