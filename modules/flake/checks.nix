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
      askpassHome = lib.findFirst (
        home: builtins.any (p: lib.getName p == "ssh-askpass") home.config.home.packages
      ) null homesHere;
      wallpapersExe = lib.getExe (
        lib.findFirst (
          p: lib.getName p == "wallpapers"
        ) (throw "wallpapers not in home.packages") wallpapersHome.config.home.packages
      );
      scriptChecks =
        let
          hc = scriptHome.config;
          d = hc.user;
          configFile = name: hc.xdg.configFile.${name}.source;
          signingKeys = import ../lib/signing-keys.nix;
          # The module's own lookup (modules/features/git.nix), so the expected
          # path tracks the declaration instead of a hardcoded layout.
          sopsSecrets = hc.sops.secrets or { };
          signingKeyFile = name: sopsSecrets.${name}.path or "/run/secrets/${name}";
          homeExe =
            name:
            lib.getExe (
              lib.findFirst (p: lib.getName p == name) (throw "${name} not in home.packages") hc.home.packages
            );
          # Expected values come from the options, not the test scripts.
          env = {
            WORK_EMAIL = d.work.email;
            WORK_BRANCH_TEMPLATE = d.work.branchNaming.template;
            WORK_BRANCH_UNTICKETED = toString d.work.branchNaming.unticketed;
            WORK_OWNER = lib.head d.work.githubOwners;
            WORK_OWNER_2 = lib.last d.work.githubOwners;
            # Shares a listed owner's prefix, as an org anyone could register.
            LOOKALIKE_WORK_OWNER = "${lib.head d.work.githubOwners}-lookalike";
            PERSONAL_EMAIL = d.email;
            PERSONAL_BRANCH_TEMPLATE = d.branchNaming.template;
            PERSONAL_BRANCH_UNTICKETED = toString d.branchNaming.unticketed;
            PERSONAL_OWNER = d.githubUser;
            # Only the work host carries the work key; everywhere else a work
            # commit signs with the personal key.
            PERSONAL_SIGNING_KEY = signingKeyFile "github-personal-signing-key";
            WORK_SIGNING_KEY = signingKeyFile (
              if hc.machine.workHost then "github-work-signing-key" else "github-personal-signing-key"
            );
            PERSONAL_SIGNING_PUB = signingKeys.personal;
            WORK_SIGNING_PUB = signingKeys.work;
          };
          # Every spelling of the employer the work options reveal; the brain
          # files must stay generic, so none may appear in them.
          employerIdentifiers =
            let
              w = d.work;
              domain = lib.last (lib.splitString "@" w.email);
              flat = [
                (baseNameOf w.flatRepos.dir)
                w.flatRepos.envVar
              ];
            in
            lib.unique (
              lib.filter (s: lib.stringLength s >= 3) (
                [
                  domain
                  (lib.head (lib.splitString "." domain))
                ]
                ++ w.githubOwners
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
            piv-ensure = {
              tools = [
                pkgs.coreutils
                pkgs.flock
                pkgs.gnugrep
                pkgs.gnused
                pkgs.python3
              ];
              args = [
                "${src}/modules/features/piv-ensure.sh"
                "${src}/modules/features/piv-dialog.sh"
              ];
            };
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
            github-pat-routing = {
              tools = [
                pkgs.coreutils
                pkgs.git
                pkgs.gnugrep
                pkgs.gnused
              ];
              args = [
                (homeExe "github-token-file")
                (homeExe "gh-pat")
                (homeExe "github-credential-helper")
              ]
              # The files the home's sops declares, else the NixOS sops-nix paths,
              # plus a path that is deliberately absent: the fail-closed matrix
              # runs against it everywhere, including where the real PATs are
              # readable (the work Mac).
              ++ map (name: sopsSecrets.${name}.path or "/run/secrets/${name}") [
                "github-personal-pat"
                "github-work-pat"
              ]
              ++ [ "/nonexistent/github-pat-routing/absent-pat" ];
            };
            worktrees-branch-template.args = [ (homeExe "worktrees") ];
            repos-routing.args = [ (homeExe "repos") ];
            brain-leak-guard = {
              tools = [ ];
              args = [ "${src}" ] ++ employerIdentifiers;
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
            # Exercises `memory export`/`restore` against temp dirs: a live WAL
            # registry, checksums, retention, the schema guard, and the graph
            # mismatch path. No root, no FalkorDB, no network.
            memory-export-restore = {
              tools = [ pkgs.python3 ];
              args = [ "${src}/modules/features/ai/memory/src" ];
            };
            manual-steps-sync = {
              tools = [ pkgs.jq ];
              args = [
                "${src}"
                "${manualStepInventory}"
              ];
            };
          }
          // lib.optionalAttrs (askpassHome != null) {
            ssh-askpass = {
              tools = [
                pkgs.coreutils
                pkgs.gnugrep
              ];
              args = [
                (lib.getExe (
                  lib.findFirst (p: lib.getName p == "ssh-askpass") null askpassHome.config.home.packages
                ))
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
          }
          // {
            # `vault <cmd>` fails closed: usage, a non-vault directory, a
            # cryptomator-cli failure, and never the password on argv.
            vault = {
              tools = [
                pkgs.bash
                pkgs.coreutils
                pkgs.fuse3
                pkgs.gnugrep
                pkgs.gnused
                pkgs.util-linux
              ];
              args = [ "${src}/modules/features/vault.sh" ];
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
              n: lib.optional (n.config.systemd.services ? "cloudflare-email@") "unit-failure"
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

        # Each laptop runs two agents: the PIV agent (login key, never
        # forwarded) and the sudo agent (touch-only handles, the only one
        # smortress sees). pam_rssh on smorespro keeps dialing fido2-agent.
        ssh-agents = evalCheck "ssh-agents" (
          toString (
            let
              ensure = cond: msg: lib.assertMsg cond "ssh-agents: ${msg}";
              home = name: config.flake.homeConfigurations.${name}.config;
              pro = home "smores@smorespro";
              work = home "sam@smoreswork";
              server = home "smores@smortress";
              units = pro.systemd.user.services;
              # ssh settings are DAG entries; the block lives under .data.
              hosts = h: lib.mapAttrs (_: e: e.data or e) h.programs.ssh.settings;
              names = h: map lib.getName h.home.packages;
              opensc = s: lib.hasInfix "opensc-pkcs11" (toString s);
              tangPi = h: (hosts h)."tang-pi";
            in
            assert
              ensure (units ? piv-agent && opensc units.piv-agent.Service.ExecStart) "smorespro has a PIV agent"
              && ensure (
                units ? fido2-agent && !opensc units.fido2-agent.Service.ExecStart
              ) "the sudo agent cannot load OpenSC"
              && ensure (
                units.fido2-agent-load.Unit.PartOf == [ "fido2-agent.service" ]
              ) "sudo handles reload with their agent"
              && ensure (!(server.systemd.user.services ? fido2-agent)) "smortress runs no local agent"
              && ensure (!(server.systemd.user.services ? piv-agent)) "smortress runs no PIV agent"
              && ensure (lib.hasSuffix "/fido2-agent" (hosts pro).smortress.ForwardAgent) "smorespro forwards only the sudo agent"
              && ensure (lib.hasSuffix "/piv-agent" (hosts pro).smortress.IdentityAgent) "smorespro logs in through the PIV agent"
              && ensure (lib.hasSuffix "/sudo-agent.sock" (hosts work).smortress.ForwardAgent) "the Mac forwards only the sudo agent"
              && ensure (lib.all (h: !((tangPi h) ? PKCS11Provider)) [
                pro
                work
              ]) "tang-pi never opens its own card session"
              && ensure (lib.all (h: (tangPi h) ? IdentityAgent) [
                pro
                work
              ]) "tang-pi signs through the PIV agent"
              && ensure (lib.all (h: !(lib.elem "yk-login" (names h))) [
                pro
                work
                server
              ]) "no manual recovery command"
              && ensure (!(lib.elem "wallpapers-askpass" (names work))) "no Keychain PIN askpass"
              && ensure (
                !((work.launchd.agents.wallpapers.config.EnvironmentVariables or { }) ? SSH_ASKPASS)
              ) "the Mac wallpaper job brings no askpass"
              && ensure (
                (work.launchd.agents.wallpapers.config.EnvironmentVariables or { }).YK_ENSURE_NO_PROMPT or null
                == "1"
              ) "the Mac wallpaper job never prompts"
              && ensure (lib.all (h: !(((hosts h)."*" or { }) ? ForwardAgent)) [
                pro
                work
              ]) "no catch-all agent forwarding"
              && ensure (lib.all (h: lib.hasInfix "piv-ensure-proxy" (hosts h).smortress.ProxyCommand) [
                pro
                work
              ]) "laptops warm the PIV agent before the tunnel"
              && ensure (
                !lib.hasInfix "piv-ensure" (hosts server).smortress.ProxyCommand
              ) "the server only tunnels"
              && ensure (lib.all (h: (hosts h).smortress.IdentitiesOnly == "yes") [
                pro
                work
              ]) "smortress offers only the PIV keys"
              && ensure (lib.elem "YK_ENSURE_NO_PROMPT=1" (
                lib.toList (pro.systemd.user.services.wallpapers.Service.Environment or [ ])
              )) "the Linux wallpaper timer never prompts"
              && ensure (lib.hasInfix "DARWIN_USER_TEMP_DIR)piv" (lib.concatStringsSep " " work.launchd.agents.piv-pin-wipe.config.ProgramArguments)) "the login wipe targets the PIN cache dir"
              && ensure (work.launchd.agents ? piv-pin-wipe) "the Mac clears the PIN cache at login";
            "ok"
          )
        );

        # The work account's bundle lives only on the work Mac
        # (modules/hosts/smoreswork/sops.nix); secrets-common.nix may never
        # regain the work PAT or the work signing key, and the Mac must carry
        # both.
        secrets-scope = evalCheck "secrets-scope" (
          let
            ensure = cond: msg: lib.assertMsg cond "secrets-scope: ${msg}";
            nixosSecrets = lib.concatMap (n: lib.attrNames (n.config.sops.secrets or { })) (
              lib.attrValues config.flake.nixosConfigurations
            );
            work = config.flake.homeConfigurations."sam@smoreswork".config.sops.secrets;
          in
          toString (
            assert
              ensure (!(lib.elem "github-work-pat" nixosSecrets)) "a NixOS host declares the work PAT"
              && ensure (
                !(lib.elem "github-work-signing-key" nixosSecrets)
              ) "a NixOS host declares the work signing key"
              && ensure (work ? github-work-pat) "the work Mac lacks the work PAT"
              && ensure (work ? github-work-signing-key) "the work Mac lacks the work signing key";
            "ok"
          )
        );

        # The generated piv-ensure-proxy must pass piv-ensure.sh its arguments in
        # order and use the cache dir the login wipe and the Seatbelt deny name.
        piv-wiring =
          let
            laptop = lib.findFirst (h: !(builtins.elem "server" h.config.machine.profiles)) null homesHere;
            proxy = lib.head (
              lib.splitString " " laptop.config.programs.ssh.settings.smortress.data.ProxyCommand
            );
            cache =
              if pkgs.stdenv.hostPlatform.isLinux then
                "\${XDG_RUNTIME_DIR:?}/piv"
              else
                "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)piv";
          in
          pkgs.runCommand "piv-wiring" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
            tr -d '\\\n' <${proxy} | grep -F 'piv-ensure.sh "' | grep -F 'opensc-pkcs11.so" "${cache}"' |
              grep -E 'piv-dialog +/nix/store/[^ ]+-piv-cache-askpass +/nix/store/[^ ]+-piv-k1.pub'
            ${lib.optionalString (!pkgs.stdenv.hostPlatform.isLinux) ''
              grep -F 'getconf DARWIN_USER_TEMP_DIR' ${src}/modules/lib/agent-sandbox.sh
              grep -F '$pin_cache/piv' ${src}/modules/lib/agent-sandbox.sh
            ''}
            touch $out
          '';

        # The two rendered planes must stay in step with the design: a Linux
        # timer that runs after the session is up, a launchd agent on the same
        # interval, and Noctalia no longer rotating.
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
            touch $out
          '';

        # The smortress alias hook: an outer interactive SSH login publishes
        # its forwarded socket (OpenSSH >= 10.1 puts it under ~/.ssh/agent,
        # older ones under /tmp); a pty-less connection or a pane that already
        # holds the alias must leave the published socket alone.
        ssh-auth-sock-hook =
          pkgs.runCommand "ssh-auth-sock-hook"
            {
              nativeBuildInputs = [
                pkgs.fish
                pkgs.zsh
                pkgs.coreutils
              ];
            }
            ''
              export HOME=$TMPDIR/home XDG_RUNTIME_DIR=$TMPDIR/run
              alias=$XDG_RUNTIME_DIR/ssh-agent.sock
              mkdir -p $HOME $XDG_RUNTIME_DIR

              # run <shell> <sock> <tty>: prints the resulting SSH_AUTH_SOCK
              # and the alias target ("-" when absent).
              run() {
                rm -f $alias
                if [ "$1" = fish ]; then
                  out=$(SSH_AUTH_SOCK=$2 SSH_TTY=$3 fish --no-config -c \
                    'if test -z "$SSH_TTY"; set -e SSH_TTY; end; source ${../features/ssh-auth-sock.fish}; echo $SSH_AUTH_SOCK')
                else
                  out=$(SSH_AUTH_SOCK=$2 SSH_TTY=$3 zsh -f -c \
                    '[ -n "$SSH_TTY" ] || unset SSH_TTY; source ${../features/ssh-auth-sock.zsh}; echo $SSH_AUTH_SOCK')
                fi
                echo "$out $(readlink $alias || echo -)"
              }
              expect() {
                [ "$1" = "$2" ] || { echo "ssh-auth-sock-hook: $3: got '$1', want '$2'" >&2; exit 1; }
              }

              for sh in fish zsh; do
                modern=$HOME/.ssh/agent/s.abc.sshd.42
                legacy=/tmp/ssh-XXXXabc/agent.42
                expect "$(run $sh $modern /dev/pts/0)" "$alias $modern" "$sh modern login"
                expect "$(run $sh $legacy /dev/pts/0)" "$alias $legacy" "$sh legacy login"
                expect "$(run $sh $modern "")" "$modern -" "$sh pty-less connection"
                expect "$(run $sh $alias /dev/pts/0)" "$alias -" "$sh pane holding the alias"
              done
              touch $out
            '';

        # Linger keeps the user manager running from boot (modules/nixos/base.nix),
        # so a default.target unit that wants graphical-session.target drags the
        # desktop up at the greeter; niri.service then starts outside
        # niri-session, whose first check reports "already running". Noctalia
        # must not want niri.service for the same reason: only niri-session may
        # launch the compositor.
        desktop-session-units =
          let
            pro = config.flake.homeConfigurations."smores@smorespro".config;
            services = pro.systemd.user.services;
            bootGraphical = lib.filter (
              name:
              lib.elem "default.target" (services.${name}.Install.WantedBy or [ ])
              && lib.elem "graphical-session.target" (services.${name}.Unit.Wants or [ ])
            ) (lib.attrNames services);
          in
          pkgs.runCommand "desktop-session-units" { } ''
            test "${lib.concatStringsSep " " bootGraphical}" = ""
            test "${lib.concatStringsSep " " services.voxtype.Unit.PartOf}" = "graphical-session.target"
            test "${lib.concatStringsSep " " services.voxtype.Unit.Wants}" = "graphical-session.target"
            test "${lib.concatStringsSep " " services.voxtype.Install.WantedBy}" = "graphical-session.target"
            test "${lib.boolToString (lib.elem "niri.service" (services.noctalia.Unit.Wants or [ ]))}" = "false"
            test "${lib.boolToString (lib.elem "niri.service" services.noctalia.Unit.After)}" = "true"
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
                pkgs.gnugrep
              ];
            }
            ''
              test ${toString (builtins.length keys.piv)} -eq 3
              # The pubkey derivation writes exactly keys.piv
              # (modules/features/ssh-keys.nix), so this is the input that would
              # have to change for a FIDO2 signing.pub to appear on disk.
              if printf '%s\n' ${
                lib.escapeShellArgs (map (k: k.key) keys.piv)
              } | grep -qxE 'k[0-9]+/signing'; then exit 1; fi
              test ${toString (builtins.length keys.sudo)} -eq 3
              test "${names keys.piv}" = "piv-k1 piv-k2 piv-k3"
              test "${names keys.sudo}" = "k1/sudo k2/sudo k3/sudo"
              # Three PIV logins plus the sops key forced into the sandbox.
              test ${toString (builtins.length config.flake.nixosConfigurations.smortress.config.users.users.smores.openssh.authorizedKeys.keys)} -eq 4
              printf '%s\n' ${lib.escapeShellArgs config.flake.nixosConfigurations.smortress.config.users.users.smores.openssh.authorizedKeys.keys} >authorized_keys
              test "$(grep -c 'command="' authorized_keys)" -eq 1
              test "$(grep -c 'no-user-rc' authorized_keys)" -eq 1
              test "$(grep -c 'no-agent-forwarding' authorized_keys)" -eq 1
              if grep -q 'sk-ssh-ed25519' authorized_keys; then exit 1; fi
              shell=${config.flake.nixosConfigurations.smortress.config.users.users.smores.shell}
              cmd=$(grep -o '/nix/store/[^"]*agent-ssh' "$shell/bin/agent-login-shell" | head -1)
              test -n "$cmd"
              grep -F "command=\"$cmd\"" authorized_keys
              # The sops signing key authenticates only into the forced sandbox:
              # present on a forced line, absent from every unforced one.
              grep -F 'command="'"$cmd"'"' authorized_keys | grep -qF ${lib.escapeShellArg (import ../lib/signing-keys.nix).personal}
              if grep -v 'command="' authorized_keys | grep -qF ${lib.escapeShellArg (import ../lib/signing-keys.nix).personal}; then exit 1; fi
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
              '') (keys.piv ++ keys.sudo)}
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
              bash -n ${src}/modules/features/piv-ensure.sh
              shellcheck ${src}/modules/features/piv-ensure.sh
              bash -n ${src}/modules/features/piv-dialog.sh
              shellcheck ${src}/modules/features/piv-dialog.sh
              bash -n ${src}/modules/features/backup/github-mirror.sh
              shellcheck ${src}/modules/features/backup/github-mirror.sh
              bash -n ${src}/modules/features/backup/github-metadata.sh
              shellcheck ${src}/modules/features/backup/github-metadata.sh
              bash -n ${src}/modules/features/backup/github-verify.sh
              shellcheck ${src}/modules/features/backup/github-verify.sh
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
        agent-sandbox-static =
          pkgs.runCommand "agent-sandbox-static-check"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            }
            ''
              grep -F -- '--clearenv' ${../lib/agent-sandbox.sh}
              grep -F -- '--unshare-pid' ${../lib/agent-sandbox.sh}
              grep -F -- '--unshare-user' ${../lib/agent-sandbox.sh}
              grep -F -- '--tmpfs /run' ${../lib/agent-sandbox.sh}
              grep -F -- 'no-user-rc' ${../nixos/ssh.nix}
              if grep -F -- 'no-touch-required' ${../nixos/ssh.nix}; then exit 1; fi
              grep -F -- 'agent-ssh' ${../nixos/ssh.nix}
              grep -F -- 'Photos' ${../lib/agent-sandbox.nix}
              grep -F -- 'gitdir/hooks' ${../lib/agent-sandbox.sh}
              grep -F -- 'gitdir/config' ${../lib/agent-sandbox.sh}
              grep -F -- '\.git/(hooks' ${../lib/agent-sandbox.sh}
              if grep -F -- '(allow default)' ${../lib/agent-sandbox.sh}; then exit 1; fi
              touch $out
            '';
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
              # Only the agent is forwarded (pam_rssh); nothing opens a socket or
              # a port on the server.
              grep -Fx 'AllowTcpForwarding no' settings
              grep -Fx 'AllowStreamLocalForwarding no' settings
              grep -Fxi 'streamlocalbindunlink no' settings
              grep -Fx 'AllowAgentForwarding yes' settings
              grep -Fx 'AllowUsers smores' settings
              grep -Fx 'PermitUserRC no' settings
              grep -Fx 'MaxAuthTries 10' settings
              grep -Fx 'LoginGraceTime 20' settings
              if grep -q '^AuthorizedKeysFile .*\.ssh/authorized_keys' settings; then exit 1; fi
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
