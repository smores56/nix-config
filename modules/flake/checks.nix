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

      mkEvalChecks =
        prefix: configs:
        lib.mapAttrs' (
          name: cfg:
          lib.nameValuePair "${prefix}-${safeName name}" (evalCheck "${prefix}-${safeName name}" cfg)
        ) configs;

      evalCheck =
        name: evaluated:
        pkgs.runCommand name
          {
            evaluated = builtins.unsafeDiscardStringContext evaluated;
          }
          ''
            touch $out
          '';

      homeChecks = mkEvalChecks "eval-home" (
        lib.mapAttrs (_: home: home.activationPackage.drvPath) config.flake.homeConfigurations
      );

      nixosChecks = mkEvalChecks "eval-nixos" (
        lib.mapAttrs (_: nixos: nixos.config.system.build.toplevel.drvPath) config.flake.nixosConfigurations
      );
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
