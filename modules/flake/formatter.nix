{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    {
      formatter = (import inputs.nixpkgs { inherit system; }).nixfmt;
    };
}
