{
  config,
  inputs,
  lib,
  mkPkgs,
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
      pkgs = mkPkgs system { };

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
        lib.mapAttrs (_: home: home.activationPackage.drvPath) (
          lib.filterAttrs (_: home: home.activationPackage.system == system) config.flake.homeConfigurations
        )
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
          d = hc.user;
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
            PERSONAL_KEY = d.sshKey;
            PERSONAL_BRANCH_TEMPLATE = d.branchNaming.template;
            PERSONAL_BRANCH_UNTICKETED = toString d.branchNaming.unticketed;
            PERSONAL_OWNER = d.githubUser;
          };
          # Every spelling of the employer the work options reveal; the brain
          # files must stay generic, so none may appear in them.
          employerIdentifiers =
            let
              w = d.work;
              domain = lib.last (lib.splitString "@" w.email);
              ownerStem = lib.removeSuffix "-" (lib.replaceStrings [ "*" ] [ "" ] w.githubOwnerGlob);
              flat = lib.optionals (w.flatRepos != null) (
                [ (baseNameOf w.flatRepos.dir) ] ++ lib.optional (w.flatRepos.envVar != null) w.flatRepos.envVar
              );
            in
            lib.unique (
              lib.filter (s: lib.stringLength s >= 3) (
                [
                  domain
                  (lib.head (lib.splitString "." domain))
                  ownerStem
                ]
                ++ flat
              )
            );
          mkScriptCheck =
            name:
            {
              tools ? [ pkgs.git ],
              args,
              extraEnv ? { },
            }:
            pkgs.runCommand name (env // extraEnv // { nativeBuildInputs = [ pkgs.bash ] ++ tools; }) ''
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
            ssh-allowed-signers = {
              tools = [ pkgs.openssh ];
              args = [ (homeExe "ssh-allowed-signers") ];
            };
            ssh-pub-keys = {
              tools = [ pkgs.openssh ];
              args = [ (homeExe "ssh-pub-keys") ];
            };
            worktrees-branch-template.args = [ (homeExe "worktrees") ];
            repos-list-links.args = [ (homeExe "repos") ];
            brain-leak-guard = {
              tools = [ ];
              args = [ "${src}" ] ++ employerIdentifiers;
            };
            bootstrap-scopes = {
              tools = [ pkgs.gawk ];
              args = [ "${src}" ];
            };
            github-mirror-probe = {
              tools = [ pkgs.git ];
              args = [ "${src}/modules/features/backup/github-mirror.sh" ];
            };
          }
          // lib.optionalAttrs pkgs.stdenv.isLinux {
            manual-steps-sync = {
              tools = [ pkgs.jq ];
              args = [
                "${src}"
                "${manualStepInventory}"
              ];
            };
          }
        );

      # Inventory for manual-steps-sync. File-derived items (hosts, sops keys,
      # Tofu providers/notifications) are parsed by the script; these are the
      # values that only exist after module evaluation.
      manualStepInventory = pkgs.writeText "manual-steps-inventory.json" (
        let
          nixos = lib.attrValues config.flake.nixosConfigurations;
          sortedUnique = xs: lib.sort builtins.lessThan (lib.unique xs);
        in
        builtins.toJSON {
          datasets = sortedUnique (
            lib.concatMap (n: lib.attrNames n.config.backup.datasets) (lib.filter (n: n.options ? backup) nixos)
          );
          services = sortedUnique (
            lib.concatMap (
              n:
              if n.options ? webProxy then
                lib.mapAttrsToList (name: _: "${n.config.networking.hostName}/${name}") n.config.webProxy.services
              else
                [ ]
            ) nixos
          );
          apps = sortedUnique (
            lib.concatMap (system: lib.attrNames config.flake.apps.${system}) (lib.attrNames config.flake.apps)
          );
          alerts = sortedUnique (
            lib.concatMap (
              n:
              lib.optional (n.config.systemd.services ? backup-freshness) "backup-freshness"
              ++ lib.optional (n.config.systemd.services ? "cloudflare-email@") "unit-failure"
            ) nixos
          );
        }
      );

      nixosChecks = mkEvalChecks "eval-nixos" (
        lib.mapAttrs (_: nixos: nixos.config.system.build.toplevel.drvPath) (
          lib.filterAttrs (
            _: nixos: nixos.config.nixpkgs.hostPlatform.system == system
          ) config.flake.nixosConfigurations
        )
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
              statix check -c ${src}/statix.toml ${src}
              touch $out
            '';

        deadnix =
          pkgs.runCommand "deadnix-check"
            {
              nativeBuildInputs = [ lintPkgs.deadnix ];
            }
            ''
              deadnix --fail --exclude 'modules/hosts/*/hardware.nix' ${src}
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
              bash -n ${src}/modules/features/backup/github-mirror.sh
              shellcheck ${src}/modules/features/backup/github-mirror.sh
              bash -n ${src}/tests/manual_steps_sync.sh
              shellcheck ${src}/tests/manual_steps_sync.sh
              touch $out
            '';

        # The old protected-services consistency check is gone with the
        # Cloudflare reconciler it guarded; the reconciler is deleted in T10.
      }
      // homeChecks
      // nixosChecks
      // scriptChecks;
    };
}
