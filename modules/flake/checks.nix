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

      # The git config is identical on every host, so any home built for
      # this system can stand in.
      gitConfigHome = lib.findFirst (home: home.activationPackage.system == system) null (
        lib.attrValues config.flake.homeConfigurations
      );
      gitRoutingChecks = lib.optionalAttrs (gitConfigHome != null) {
        git-work-routing =
          pkgs.runCommand "git-work-routing"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.git
              ];
            }
            ''
              bash ${src}/tests/git_work_routing.sh ${gitConfigHome.config.xdg.configFile."git/config".source}
              touch $out
            '';
      };

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
              statix check -c ${src} ${src}
              touch $out
            '';

        unit-tests =
          pkgs.runCommand "unit-tests"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.git
              ];
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
      // nixosChecks
      // gitRoutingChecks;
    };
}
