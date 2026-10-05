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

      # Identity tests run a tests/*.sh script against files from a generated
      # home. The identity config (git, ssh, fish key loading) is the same on
      # every host, so any home built for this system can stand in.
      identityHome = lib.findFirst (home: home.activationPackage.system == system) null (
        lib.attrValues config.flake.homeConfigurations
      );
      identityChecks =
        let
          hc = identityHome.config;
          d = hc.dotfiles;
          configFile = name: hc.xdg.configFile.${name}.source;
          homeExe =
            name:
            lib.getExe (
              lib.findFirst (p: lib.getName p == name) (throw "${name} not in home.packages") hc.home.packages
            );
          # Expected values come from the options, not the test scripts.
          env = {
            WORK_EMAIL = d.work.email;
            WORK_KEY = d.work.sshKey;
            WORK_SSH_CONFIG = d.work.sshConfig;
            WORK_PREFIX = d.work.branchPrefix;
            WORK_OWNER = lib.replaceStrings [ "*" ] [ "routing-test" ] d.work.githubOwnerGlob;
            PERSONAL_EMAIL = d.email;
            PERSONAL_KEY = "~/.ssh/id_personal";
            PERSONAL_PREFIX = d.branchPrefix;
            PERSONAL_OWNER = d.githubUser;
          };
          mkScriptCheck =
            name:
            { tools, args }:
            pkgs.runCommand name (env // { nativeBuildInputs = [ pkgs.bash ] ++ tools; }) ''
              bash ${src}/tests/${lib.replaceStrings [ "-" ] [ "_" ] name}.sh ${lib.escapeShellArgs args}
              touch $out
            '';
        in
        lib.optionalAttrs (identityHome != null) (
          lib.mapAttrs mkScriptCheck {
            git-work-routing = {
              tools = [ pkgs.git ];
              args = [ (configFile "git/config") ];
            };
            ssh-agent-keys = {
              tools = [
                pkgs.fish
                pkgs.openssh
              ];
              args = [ (configFile "fish/functions/__load_ssh_keys.fish") ];
            };
            ssh-allowed-signers = {
              tools = [ pkgs.openssh ];
              args = [ (homeExe "ssh-allowed-signers") ];
            };
            worktrees-branch-prefix = {
              tools = [ pkgs.git ];
              args = [
                (configFile "git/config")
                (homeExe "worktrees")
              ];
            };
          }
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
      // identityChecks;
    };
}
