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
      # wallpapers also only renders on graphical hosts; pick by its package so
      # the check does not depend on attribute ordering.
      wallpapersHome = lib.findFirst (
        home: builtins.any (p: lib.getName p == "wallpapers") home.config.home.packages
      ) null homesHere;
      wallpapersExe = lib.getExe (
        lib.findFirst (
          p: lib.getName p == "wallpapers"
        ) (throw "wallpapers not in home.packages") wallpapersHome.config.home.packages
      );
      askpassExe = lib.getExe (
        lib.findFirst (
          p: lib.getName p == "wallpapers-askpass"
        ) (throw "wallpapers-askpass not in home.packages") wallpapersHome.config.home.packages
      );
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
                pkgs.ssh-to-age
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
          // lib.optionalAttrs (wallpapersHome != null) {
            wallpapers = {
              tools = [
                pkgs.coreutils
                pkgs.imagemagick
                pkgs.gnugrep
              ];
              args = [ wallpapersExe ];
            };
            wallpapers-askpass = {
              tools = [ pkgs.coreutils ];
              args = [ askpassExe ];
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
        # Build every operator app. writeShellApplication runs shellcheck at
        # build time; without this, a lint error in an app only shows up when
        # someone runs it (which is how a broken `install` reached main).
        apps = pkgs.linkFarm "apps-check" (
          map
            (p: {
              inherit (p) name;
              path = p;
            })
            [
              inputs.self.packages.${system}.bootstrap
              inputs.self.packages.${system}.host-key
              inputs.self.packages.${system}.install
              inputs.self.packages.${system}.key-backup
              inputs.self.packages.${system}.key-restore
              inputs.self.packages.${system}.proton-auth
            ]
        );

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

        # The two rendered planes must stay in step with the design: a Linux
        # timer that runs after the session is up, a launchd agent that can
        # answer the PIV PIN unattended, and Noctalia no longer rotating.
        wallpapers-units =
          let
            pro = config.flake.homeConfigurations."smores@smorespro".config;
            work = config.flake.homeConfigurations."sam@smoreswork".config;
          in
          pkgs.runCommand "wallpapers-units" { } ''
            test "${pro.systemd.user.services.wallpapers.Service.Type}" = "oneshot"
            test "${pro.systemd.user.services.wallpapers.Service.TimeoutStartSec}" = "20min"
            test "${lib.concatStringsSep " " pro.systemd.user.services.wallpapers.Unit.After}" = "graphical-session.target"
            test "${lib.concatStringsSep " " pro.systemd.user.services.wallpapers.Install.WantedBy}" = "graphical-session.target"
            test "${lib.boolToString (lib.any (lib.hasInfix "sync") pro.systemd.user.services.wallpapers.Service.ExecStart)}" = "true"
            test "${pro.systemd.user.timers.wallpapers.Timer.OnUnitInactiveSec}" = "3h"
            test "${lib.concatStringsSep " " pro.systemd.user.timers.wallpapers.Install.WantedBy}" = "timers.target"
            test "${lib.boolToString pro.programs.noctalia.settings.wallpaper.automation.enabled}" = "false"
            test "${toString work.launchd.agents.wallpapers.config.StartInterval}" = "10800"
            test "${work.launchd.agents.wallpapers.config.EnvironmentVariables.SSH_ASKPASS_REQUIRE}" = "force"
            test "${lib.boolToString (lib.hasInfix "wallpapers-askpass" work.launchd.agents.wallpapers.config.EnvironmentVariables.SSH_ASKPASS)}" = "true"
            touch $out
          '';

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
              test ${toString (builtins.length config.flake.nixosConfigurations.smortress.config.users.users.smores.openssh.authorizedKeys.keys)} -eq 6
              printf '%s\n' ${lib.escapeShellArgs config.flake.nixosConfigurations.smortress.config.users.users.smores.openssh.authorizedKeys.keys} >authorized_keys
              test "$(grep -c 'command="' authorized_keys)" -eq 3
              test "$(grep -c 'no-user-rc' authorized_keys)" -eq 3
              test "$(grep -c 'no-agent-forwarding' authorized_keys)" -eq 3
              test ${
                toString (
                  builtins.length (
                    builtins.filter (s: s != "") (
                      lib.splitString "\n"
                        config.flake.nixosConfigurations.smortress.config.environment.etc."ssh/sudo_authorized_keys".text
                    )
                  )
                )
              } -eq 3

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
      // scriptChecks
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        sshd-settings =
          pkgs.runCommand "sshd-settings-check"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.openssh
              ];
            }
            ''
              key=$(mktemp)
              rm -f "$key"
              ssh-keygen -q -t ed25519 -N "" -f "$key"
              sshd -T -f ${
                config.flake.nixosConfigurations.smortress.config.environment.etc."ssh/sshd_config".source
              } -h "$key" 2>/dev/null >settings
              grep -Fx 'AuthenticationMethods publickey' settings
              grep -Fx 'pubkeyauthoptions verify-required' settings
              grep -Fx 'PasswordAuthentication no' settings
              grep -Fx 'KbdInteractiveAuthentication no' settings
              grep -Fx 'PermitRootLogin no' settings
              grep -Fx 'PermitEmptyPasswords no' settings
              grep -Fx 'AllowTcpForwarding no' settings
              grep -Fx 'AllowAgentForwarding yes' settings
              grep -Fx 'AllowUsers smores' settings
              grep -Fx 'PermitUserRC no' settings
              grep -Fx 'MaxAuthTries 10' settings
              grep -Fx 'LoginGraceTime 20' settings
              ! grep -q '^AuthorizedKeysFile .*\.ssh/authorized_keys' settings
              grep -q '^listenaddress 127\.0\.0\.1:' settings
              touch $out
            '';

        # The auth stack is the security property: a jump that skips the wrong
        # line, a control that falls through, or a probe in the wrong slot
        # silently changes which credential is accepted. A pam_exec probe that
        # cannot run returns SYSTEM_ERR; under default=ignore the gate is
        # skipped, pam_p11 then runs, and only its authinfo_unavail=ignore keeps
        # that from locking the password out.
        pam-auth-gates =
          let
            cfg = config.flake.nixosConfigurations.smorespro.config;
            rendered =
              service: pkgs.writeText "pam-${service}.rendered" cfg.security.pam.services.${service}.text;
            expected =
              name: lines: pkgs.writeText "pam-${name}.expected" (lib.concatStringsSep "\n" lines + "\n");
            # One line per auth rule: control, module basename, then the args
            # with every store path reduced to its basename. That pins the
            # order, the controls, the arguments and which probe sits where
            # without depending on store hashes. Rules carrying no store path
            # (a bare pam_deny) pass through unchanged.
            normalize = ''
              ${pkgs.gawk}/bin/awk '
                $1 == "auth" {
                  s = $0; sub(/ # .*$/, "", s)
                  i = index(s, " /nix/store/")
                  if (i == 0) { print s; next }
                  ctl = substr(s, 6, i - 6)
                  n = split(substr(s, i + 1), t, " ")
                  out = ctl
                  for (j = 1; j <= n; j++) {
                    if (t[j] ~ /^\/nix\/store\//) { m = split(t[j], p, "/"); out = out " " p[m] }
                    else out = out " " t[j]
                  }
                  print out
                }' "$1"
            '';
            probes = ''
              ${pkgs.gawk}/bin/awk '$1 == "auth" && /pam_exec\.so/ {
                p = ""
                for (i = 1; i <= NF; i++)
                  if ($i ~ /^\/nix\/store\// && $i !~ /pam_exec\.so$/) p = $i
                print p
              }' "$1"
            '';
          in
          pkgs.runCommand "pam-auth-gates-check"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.diffutils
                pkgs.gawk
                pkgs.gnugrep
              ];
            }
            ''
              normalize() {
                ${normalize}
              }
              probes() {
                ${probes}
              }

              # greeter: lid gate -> fprintd -> card gate -> p11 -> unix.
              normalize ${rendered "greetd"} > greetd.stack
              diff -u ${
                expected "greetd" [
                  "[success=1 default=ignore] pam_exec.so quiet quiet_log pam-lid-closed"
                  "sufficient pam_fprintd.so timeout=5 max-tries=1"
                  "[success=1 default=ignore] pam_exec.so quiet quiet_log pam-ccid-absent"
                  "[success=done authinfo_unavail=ignore default=die] pam_p11.so opensc-pkcs11.so ^[0-9]{8}$"
                  "sufficient pam_unix.so likeauth nullok try_first_pass"
                  "required pam_deny.so"
                ]
              } greetd.stack

              # lock screen: card gate -> p11 -> unix, and no pam_fprintd
              # (Noctalia drives the sensor over D-Bus).
              normalize ${rendered "login"} > login.stack
              diff -u ${
                expected "login" [
                  "[success=1 default=ignore] pam_exec.so quiet quiet_log pam-ccid-absent"
                  "[success=done authinfo_unavail=ignore default=die] pam_p11.so opensc-pkcs11.so ^[0-9]{8}$"
                  "sufficient pam_unix.so likeauth nullok try_first_pass"
                  "required pam_deny.so"
                ]
              } login.stack

              # Both probes must be executable store paths: a relative or
              # missing probe is a SYSTEM_ERR, and for the card gate that means
              # pam_p11 runs unguarded on every attempt.
              probes ${rendered "greetd"} > greetd.probes
              probes ${rendered "login"} > login.probes
              test "$(wc -l < greetd.probes)" -eq 2
              test "$(wc -l < login.probes)" -eq 1
              for p in $(cat greetd.probes login.probes); do test -x "$p"; done

              # The gates belong to smorespro's two services alone. A stray
              # global p11/fprintd option would put a PIN-or-nothing module in
              # front of sudo and every admin prompt, and this check would
              # otherwise stay green.
              ${lib.concatStringsSep "\n" (
                map (svc: "! grep -qE 'pam_(p11|fprintd|exec)\\.so' ${rendered svc}") [
                  "sudo"
                  "su"
                  "polkit-1"
                ]
              )}

              touch $out
            '';
      };
    };
}
