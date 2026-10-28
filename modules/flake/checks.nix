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

      # The memory package's modules and tests import mcp, httpx, anyio,
      # starlette, and redis (the exact FalkorDB presence check); mcp brings the
      # rest transitively. One env for the whole suite keeps the pinned nixpkgs
      # and its versions in one place.
      unitTestsPython = pkgs.python3.withPackages (ps: [
        ps.mcp
        ps.redis
      ]);

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
            # Linux selects the key from the agent; Darwin keeps the software
            # key path for the work Mac.
            SIGNING_KEY_MODE = if hc.programs.git.settings.gpg.ssh ? defaultKeyCommand then "agent" else "file";
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
          {
            key-bundle = {
              tools = [
                pkgs.coreutils
                pkgs.findutils
                pkgs.gawk
                pkgs.gnutar
                pkgs.gzip
                pkgs.gnugrep
                pkgs.openssh
              ];
              args = [
                (lib.getExe inputs.self.packages.${system}.key-backup)
                (lib.getExe inputs.self.packages.${system}.key-restore)
              ];
            };
          }
          // lib.optionalAttrs (zshHome != null) {
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
            ssh-pin-askpass = {
              tools = [
                pkgs.coreutils
                pkgs.gnugrep
              ];
              args = [ (homeExe "ssh-pin-askpass") ];
            };
            ssh-pub-keys = {
              tools = [ pkgs.openssh ];
              args = [ (homeExe "ssh-pub-keys") ];
            };
            ssh-no-private-keys = {
              tools = [
                pkgs.openssh
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnugrep
              ];
              args = [ (homeExe "ssh-no-private-keys") ];
            };
            # The admin-key wrapper must fail closed: no identity file, and no
            # leftover plaintext key that sops would load behind its back.
            sops-age-key = {
              tools = [ ];
              args = [ hc.home.sessionVariables.SOPS_AGE_KEY_CMD ];
            };
            worktrees-branch-template.args = [ (homeExe "worktrees") ];
            repos-routing.args = [ (homeExe "repos") ];
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
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # These checks need Linux-only tools (inotify-tools, util-linux
            # flock), so they must not be evaluated or built on Darwin.
            github-metadata = {
              tools = [
                pkgs.git
                pkgs.jq
                pkgs.util-linux
                pkgs.coreutils
                pkgs.findutils
                pkgs.gawk
              ];
              args = [
                "${src}/modules/features/backup/github-metadata.sh"
                "${src}/modules/features/backup/github-verify.sh"
              ];
            };
            backup-watch = {
              tools = [
                pkgs.inotify-tools
                pkgs.coreutils
                pkgs.findutils
              ];
              args = [ "${src}/modules/features/backup/backup_watch.sh" ];
            };
            restore-drill = {
              tools = [
                pkgs.util-linux
                pkgs.coreutils
              ];
              args = [ "${src}/modules/features/backup/drills/restore-drill.sh" ];
            };
            # Exercises `memory export`/`restore` against temp dirs: a live WAL
            # registry, checksums, retention, the schema guard, and the graph
            # mismatch path. No root, no FalkorDB, no network.
            memory-export-restore = {
              tools = [ pkgs.python3 ];
              args = [ "${src}/modules/features/ai/memory/src" ];
            };
            backup-plain = {
              tools = [
                # The same rclone generation the NixOS module overlays in
                # (nixpkgs-unstable, 1.75.1); the pinned nixpkgs rclone 1.74.4
                # predates --files-from0, which the scoped check needs.
                inputs.nixpkgs-unstable.legacyPackages.${system}.rclone
                pkgs.jq
                pkgs.coreutils
                pkgs.util-linux
                pkgs.findutils
              ];
              args = [ "${src}/modules/features/backup/backup.sh" ];
            };
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
        desktop-bindings = evalCheck "desktop-bindings" (
          toString (
            import ../../tests/shared_desktop_bindings.nix {
              inherit lib;
              niriBindings =
                config.flake.homeConfigurations."smores@smorespro".config.programs.niri.settings.binds;
              aerospaceBindings =
                config.flake.homeConfigurations."sam@smoreswork".config.programs.aerospace.settings.mode.main.binding;
            }
          )
        );

        yubikey-lists =
          let
            keys = import ../lib/yubikey-keys.nix;
            file =
              ext: k: content:
              pkgs.writeText "${lib.replaceStrings [ "/" ] [ "-" ] k.key}.${ext}" content;
            names = xs: lib.concatStringsSep " " (map (k: k.key) xs);
          in
          pkgs.runCommand "yubikey-lists"
            {
              nativeBuildInputs = [
                pkgs.openssh
                pkgs.openssl
              ];
            }
            ''
              test ${toString (builtins.length keys.piv)} -eq 3
              test ${toString (builtins.length keys.signing)} -eq 3
              test ${toString (builtins.length keys.sudo)} -eq 3
              test "${names keys.piv}" = "piv-k1 piv-k2 piv-k3"
              test "${names keys.signing}" = "k1/signing k2/signing k3/signing"
              test "${names keys.sudo}" = "k1/sudo k2/sudo k3/sudo"

              ${lib.concatMapStrings (k: ''
                ssh-keygen -l -f ${file "pub" k k.pubkey} >/dev/null
              '') (keys.piv ++ keys.signing ++ keys.sudo)}
              ${lib.concatMapStrings (k: ''
                openssl x509 -in ${file "crt" k k.cert} -noout -subject >/dev/null
              '') keys.piv}
              touch $out
            '';

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

        slack-mcp =
          pkgs.runCommand "slack-mcp-check"
            {
              nativeBuildInputs = [ pkgs.nodejs_24 ];
            }
            ''
              node --check ${src}/modules/features/ai/slack-mcp/session.mjs
              node --check ${src}/modules/features/ai/slack-mcp/leveldb.mjs
              node --test ${src}/tests/slack-mcp.test.mjs ${src}/tests/slack-leveldb-state.test.mjs
              touch $out
            '';

        slack-mcp-module = import ../../tests/slack-mcp-module.nix { inherit pkgs; };
        slack-mcp-backend = import ../features/ai/slack-mcp/backend.nix { inherit pkgs; };

        unit-tests =
          pkgs.runCommand "unit-tests"
            {
              nativeBuildInputs = [
                unitTestsPython
                pkgs.git
              ];
              # The brain-run tests pin TZ=America/New_York and call tzset();
              # without zoneinfo the sandbox falls back to UTC and they fail.
              TZDIR = "${pkgs.tzdata}/share/zoneinfo";
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
              bash -n ${src}/modules/features/backup/github-metadata.sh
              shellcheck ${src}/modules/features/backup/github-metadata.sh
              bash -n ${src}/modules/features/backup/github-verify.sh
              shellcheck ${src}/modules/features/backup/github-verify.sh
              bash -n ${src}/modules/features/backup/backup_watch.sh
              shellcheck ${src}/modules/features/backup/backup_watch.sh
              bash -n ${src}/modules/features/backup/backup.sh
              shellcheck ${src}/modules/features/backup/backup.sh
              bash -n ${src}/tests/backup_watch.sh
              shellcheck ${src}/tests/backup_watch.sh
              bash -n ${src}/tests/backup_plain.sh
              shellcheck ${src}/tests/backup_plain.sh
              bash -n ${src}/tests/restore_drill.sh
              shellcheck ${src}/tests/restore_drill.sh
              bash -n ${src}/tests/memory_export_restore.sh
              shellcheck ${src}/tests/memory_export_restore.sh
              bash -n ${src}/tests/manual_steps_sync.sh
              shellcheck ${src}/tests/manual_steps_sync.sh
              bash -n ${src}/tests/github_metadata.sh
              shellcheck ${src}/tests/github_metadata.sh
              touch $out
            '';

        tofu-format =
          pkgs.runCommand "tofu-format-check"
            {
              nativeBuildInputs = [ pkgs.opentofu ];
            }
            ''
              tofu fmt -check -recursive ${src}/tofu
              touch $out
            '';
      }
      // homeChecks
      // nixosChecks
      // scriptChecks;
    };
}
