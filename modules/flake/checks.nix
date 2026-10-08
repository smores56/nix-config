{
  config,
  inputs,
  lib,
  nixpkgsFor,
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
      pkgs = import (nixpkgsFor system) {
        inherit system;
        config.allowUnfree = true;
      };

      # Lint tools come from one nixpkgs on every platform so the format check
      # agrees with `nix fmt` wherever it runs.
      lintPkgs = import inputs.nixpkgs { inherit system; };

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

      # Script checks run a tests/*.sh script against tools and files from a
      # generated home. What they exercise (git/ssh identity, repo tooling)
      # is the same on every host, so any home built for this system can
      # stand in.
      homesHere = lib.filter (home: home.activationPackage.system == system) (
        lib.attrValues config.flake.homeConfigurations
      );
      scriptHome = lib.findFirst (_: true) null homesHere;
      # zsh only renders on work hosts, so its check needs a home that has it.
      zshHome = lib.findFirst (home: home.config.programs.zsh.enable) null homesHere;
      scriptChecks =
        let
          hc = scriptHome.config;
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
            WORK_BRANCH_TEMPLATE = d.work.branchNaming.template;
            WORK_BRANCH_UNTICKETED = toString d.work.branchNaming.unticketed;
            WORK_OWNER = lib.replaceStrings [ "*" ] [ "routing-test" ] d.work.githubOwnerGlob;
            PERSONAL_EMAIL = d.email;
            PERSONAL_KEY = "~/.ssh/id_personal";
            PERSONAL_BRANCH_TEMPLATE = d.branchNaming.template;
            PERSONAL_BRANCH_UNTICKETED = toString d.branchNaming.unticketed;
            PERSONAL_OWNER = d.githubUser;
          };
          mkScriptCheck =
            name:
            {
              tools ? [ pkgs.git ],
              args,
            }:
            pkgs.runCommand name (env // { nativeBuildInputs = [ pkgs.bash ] ++ tools; }) ''
              bash ${src}/tests/${lib.replaceStrings [ "-" ] [ "_" ] name}.sh ${lib.escapeShellArgs args}
              touch $out
            '';
        in
        lib.mapAttrs mkScriptCheck (
          lib.optionalAttrs (zshHome != null) {
            zsh-config = {
              tools = [ pkgs.zsh ];
              args =
                let
                  zc = zshHome.config;
                  # dotDir is absolute; home.file keys are relative to home.
                  dotDir = lib.removePrefix "${zc.home.homeDirectory}/" zc.programs.zsh.dotDir;
                in
                map (name: zc.home.file.${name}.source) [
                  ".zshenv"
                  "${dotDir}/.zshenv"
                  "${dotDir}/.zprofile"
                  "${dotDir}/.zshrc"
                ];
            };
          }
          // lib.optionalAttrs (scriptHome != null) {
            git-work-routing = {
              args = [ (configFile "git/config") ];
            };
            ssh-agent-keys = {
              tools = [ pkgs.openssh ];
              args = [ (homeExe "load-ssh-keys") ];
            };
            ssh-allowed-signers = {
              tools = [ pkgs.openssh ];
              args = [ (homeExe "ssh-allowed-signers") ];
            };
            worktrees-branch-template.args = [ (homeExe "worktrees") ];
            repos-list-links.args = [ (homeExe "repos") ];
            work-repo-links.args = [ (lib.getExe (import ../lib/work-repo-links.nix { inherit pkgs; })) ];
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
              nativeBuildInputs = [ lintPkgs.nixfmt-tree ];
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
              nativeBuildInputs = [ lintPkgs.statix ];
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
              bash -n ${src}/modules/features/backup/drills/restore-drill.sh
              shellcheck ${src}/modules/features/backup/drills/restore-drill.sh
              touch $out
            '';
      }
      // homeChecks
      // nixosChecks
      // scriptChecks;
    };
}
