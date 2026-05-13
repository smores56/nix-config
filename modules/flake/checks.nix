{
  config,
  inputs,
  lib,
  ...
}:
let
  safeName =
    lib.replaceStrings
      [
        "@"
        "."
        "/"
      ]
      [
        "-"
        "-"
        "-"
      ];
in
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      src = inputs.self;

      evalCheck =
        name: evaluated:
        pkgs.runCommand name
          {
            evaluated = builtins.unsafeDiscardStringContext evaluated;
          }
          ''
            touch $out
          '';

      homeChecks = lib.mapAttrs' (
        name: home:
        lib.nameValuePair "eval-home-${safeName name}" (
          evalCheck "eval-home-${safeName name}" home.activationPackage.drvPath
        )
      ) config.flake.homeConfigurations;

      nixosChecks = lib.mapAttrs' (
        name: nixos:
        lib.nameValuePair "eval-nixos-${safeName name}" (
          evalCheck "eval-nixos-${safeName name}" nixos.config.system.build.toplevel.drvPath
        )
      ) config.flake.nixosConfigurations;
    in
    {
      checks = {
        format =
          pkgs.runCommand "format-check"
            {
              nativeBuildInputs = [ pkgs.nixfmt-tree ];
            }
            ''
              cp -R --no-preserve=mode,ownership ${src} source
              cd source
              treefmt --ci --walk filesystem --tree-root "$PWD" .
              touch $out
            '';

        statix =
          pkgs.runCommand "statix-check"
            {
              nativeBuildInputs = [ pkgs.statix ];
            }
            ''
              statix check ${src}
              touch $out
            '';

        niri-equalize-tests =
          pkgs.runCommand "niri-equalize-tests"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              cp -R --no-preserve=mode,ownership ${src} source
              cd source
              python -m unittest discover -s tests -p 'test_*.py'
              touch $out
            '';

        bootstrap =
          pkgs.runCommand "bootstrap-check"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.shellcheck
              ];
            }
            ''
              bash -n ${src}/bootstrap.sh
              shellcheck ${src}/bootstrap.sh
              touch $out
            '';
      }
      // homeChecks
      // nixosChecks;
    };
}
