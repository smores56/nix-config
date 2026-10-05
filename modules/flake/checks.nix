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
          let
            d = gitConfigHome.config.dotfiles;
          in
          pkgs.runCommand "git-work-routing"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.git
              ];
              WORK_EMAIL = d.work.email;
              WORK_KEY = d.work.sshKey;
              WORK_SSH_CONFIG = d.work.sshConfig;
              WORK_PREFIX = d.work.branchPrefix;
              WORK_OWNER = lib.replaceStrings [ "*" ] [ "routing-test" ] d.work.githubOwnerGlob;
              PERSONAL_EMAIL = d.email;
              PERSONAL_KEY = "~/.ssh/id_personal";
              PERSONAL_PREFIX = d.branchPrefix;
              PERSONAL_OWNER = d.githubUser;
            }
            ''
              bash ${src}/tests/git_work_routing.sh ${gitConfigHome.config.xdg.configFile."git/config".source}
              touch $out
            '';
      };

      sshAgentChecks = lib.optionalAttrs (gitConfigHome != null) {
        ssh-agent-keys =
          pkgs.runCommand "ssh-agent-keys"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.fish
                pkgs.openssh
              ];
            }
            ''
              bash ${src}/tests/ssh_agent_keys.sh ${
                gitConfigHome.config.xdg.configFile."fish/functions/__load_ssh_keys.fish".source
              }
              touch $out
            '';
      };

      allowedSignersChecks = lib.optionalAttrs (gitConfigHome != null) {
        ssh-allowed-signers =
          pkgs.runCommand "ssh-allowed-signers"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.openssh
              ];
              PERSONAL_EMAIL = gitConfigHome.config.dotfiles.email;
              WORK_EMAIL = gitConfigHome.config.dotfiles.work.email;
            }
            ''
              bash ${src}/tests/ssh_allowed_signers.sh ${
                lib.getExe (
                  lib.findFirst (
                    p: lib.getName p == "ssh-allowed-signers"
                  ) (throw "ssh-allowed-signers not in home.packages") gitConfigHome.config.home.packages
                )
              }
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
      // gitRoutingChecks
      // sshAgentChecks
      // allowedSignersChecks;
    };
}
