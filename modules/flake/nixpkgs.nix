{ inputs, lib, ... }:
{
  # The one place that picks a nixpkgs per system; homes, checks and the
  # formatter all import through it so a platform never mixes package sets.
  _module.args.nixpkgsFor =
    system: if lib.hasSuffix "-darwin" system then inputs.nixpkgs-darwin else inputs.nixpkgs;
}
