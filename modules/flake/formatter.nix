{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
    in
    {
      formatter = pkgs.writeShellApplication {
        name = "nix-config-fmt";
        runtimeInputs = [ pkgs.nixfmt-tree ];
        text = ''
          check=false
          if [ "''${1:-}" = "--check" ]; then
            check=true
            shift
          fi

          if [ "$#" -eq 0 ]; then
            set -- .
          fi

          if [ "$check" = true ]; then
            exec treefmt --ci "$@"
          fi

          exec treefmt "$@"
        '';
      };
    };
}
