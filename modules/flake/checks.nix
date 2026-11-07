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

      # One nixpkgs for lint tools so the format check agrees with `nix fmt`.
      lintPkgs = import inputs.nixpkgs { inherit system; };

      src = inputs.self;

      # One env for the memory suite's imports (mcp brings the rest transitively).
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

      # Any home built for this system serves: these exercise host-independent tooling.
      homesHere = lib.filter (home: home.activationPackage.system == system) (
        lib.attrValues config.flake.homeConfigurations
      );
      scriptHome = lib.findFirst (_: true) null homesHere;
      # zsh only renders on work hosts.
      zshHome = lib.findFirst (home: home.config.programs.zsh.enable) null homesHere;
      # wallpapers only renders on graphical hosts; pick by package, not attribute order.
      wallpapersHome = lib.findFirst (
        home: builtins.any (p: lib.getName p == "wallpapers") home.config.home.packages
      ) null homesHere;
      brewHome = lib.findFirst (home: home.config.xdg.configFile ? "homebrew/Brewfile") null homesHere;
      askpassHome = lib.findFirst (
        home: builtins.any (p: lib.getName p == "ssh-askpass") home.config.home.packages
      ) null homesHere;
      claudeConfigHome = lib.findFirst (
        home: builtins.any (p: lib.getName p == "claude-config") home.config.home.packages
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
          secretPath = import ../lib/secret-path.nix hc;
          homeExe =
            name:
            lib.getExe (
              lib.findFirst (p: lib.getName p == name) (throw "${name} not in home.packages") hc.home.packages
            );
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
            # Only the work host carries the work key; elsewhere work commits sign with the personal key.
            PERSONAL_SIGNING_KEY = secretPath "github-personal-signing-key";
            WORK_SIGNING_KEY = secretPath (
              if hc.machine.workHost then "github-work-signing-key" else "github-personal-signing-key"
            );
            PERSONAL_SIGNING_PUB = signingKeys.personal;
            WORK_SIGNING_PUB = signingKeys.work;
          };
          # Every spelling of the employer the work options reveal; the harvester
          # and brain skill must stay generic, so none may appear in them.
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
          // lib.optionalAttrs (brewHome != null) {
            brewfile = {
              tools = [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
              ];
              args = [ brewHome.config.xdg.configFile."homebrew/Brewfile".source ];
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
            # The admin-key wrapper must fail closed: no identity file, and no leftover plaintext key.
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
              # The home's sops files, else the NixOS sops-nix paths, plus a deliberately absent
              # path so the fail-closed matrix also runs where real PATs are readable.
              ++ map secretPath [
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
            # Linux-only tools (inotify-tools, flock): must not build on Darwin.
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
          // lib.optionalAttrs (claudeConfigHome != null) {
            claude-config = {
              tools = [
                pkgs.coreutils
                pkgs.jq
              ];
              args = [
                (lib.getExe (
                  lib.findFirst (p: lib.getName p == "claude-config") null claudeConfigHome.config.home.packages
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
            md-structure = {
              tools = [
                pkgs.bash
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
              ];
              args = [
                "${src}/modules/features/md-structure.sh"
                "${src}/modules/features/md-structure.prompt.md"
              ];
            };
          }
        );

      # Values that only exist after module evaluation.
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
        # writeShellApplication shellcheck-lints at build time; build every operator app so a lint error fails here.
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

        # The laptops differ only where tests/laptop-parity-sanctioned.nix says so. Both homes evaluate
        # from any system, so this runs everywhere. The mutations prove it still catches drift.
        laptop-parity =
          let
            work = config.flake.homeConfigurations."sam@smoreswork".config;
            pro = config.flake.homeConfigurations."smores@smorespro".config;
            sanctioned = import ../../tests/laptop-parity-sanctioned.nix { inherit lib; };
            parity = import ../../tests/laptop_parity.nix;
            passes =
              args:
              (builtins.tryEval (
                builtins.deepSeq (parity (
                  {
                    inherit
                      lib
                      work
                      pro
                      sanctioned
                      ;
                  }
                  // args
                )) true
              )).success;
          in
          evalCheck "laptop-parity" (
            toString (
              assert
                parity {
                  inherit
                    lib
                    work
                    pro
                    sanctioned
                    ;
                } == "ok";
              assert lib.all (mutation: !passes { pro = lib.recursiveUpdate pro mutation; }) [
                { home.packages = pro.home.packages ++ [ pkgs.hello ]; }
                { user.shellAbbrs.drift = "true"; }
                { programs.ssh.settings.drift.HostName = "example.org"; }
                { systemd.user.services.drift = { }; }
                { home.activation.drift = { }; }
                { programs.drift.enable = true; }
              ];
              assert
                !passes {
                  sanctioned = sanctioned // {
                    packages = sanctioned.packages // {
                      hello = "inherent: stale on purpose";
                    };
                  };
                };
              assert
                !passes {
                  sanctioned = sanctioned // {
                    packages = sanctioned.packages // {
                      ${lib.head (lib.attrNames sanctioned.packages)} = "no tag";
                    };
                  };
                };
              "ok"
            )
          );

        # NixOS collects through its root timer; a non-NixOS home's agent is the only collector
        # there, and NixOS homes expire their home-manager generations for the next root run. The
        # Mac also shares its SSH transports through a socket path that fits macOS's 104-byte limit
        # (ssh appends a 17-byte suffix while binding).
        home-maintenance = evalCheck "home-maintenance" (
          toString (
            let
              ensure = cond: msg: lib.assertMsg cond "home-maintenance: ${msg}";
              work = config.flake.homeConfigurations."sam@smoreswork".config;
              mux = work.programs.ssh.settings."*".data or work.programs.ssh.settings."*";
              socketBytes =
                lib.stringLength (lib.replaceStrings [ "%C" ] [ (lib.fixedWidthString 40 "x" "") ] mux.ControlPath)
                + 17;
              nonNixosHomes = lib.filterAttrs (_: h: !h.config.machine.nixos) config.flake.homeConfigurations;
              nixosHomes = lib.filterAttrs (_: h: h.config.machine.nixos) config.flake.homeConfigurations;
            in
            ensure (lib.all (h: h.config.nix.gc.automatic) (lib.attrValues nonNixosHomes)) (
              "every non-NixOS home collects garbage"
            )
            && ensure (lib.all (h: h.config.nix.gc.automatic) (
              lib.attrValues config.flake.nixosConfigurations
            )) "every NixOS host collects garbage"
            && ensure (lib.all (h: h.config.services.home-manager.autoExpire.enable) (
              lib.attrValues nixosHomes
            )) "every NixOS home expires old generations"
            && ensure (mux.ControlMaster == "auto") "the Mac multiplexes SSH connections"
            && ensure (socketBytes <= 104) "the control socket path is ${toString socketBytes} bytes"
          )
        );

        # Two agents per laptop: PIV (login key, never forwarded) and sudo (touch-only, the only one smortress sees).
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

        # The work bundle lives only on the work Mac; secrets-common.nix must never carry the work PAT or signing key.
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

        # The memory service is the only agent memory: Claude's own is off wherever it is configured,
        # maki's bundled one is off wherever maki is, and the personal laptop reaches smortress's store.
        single-memory = evalCheck "single-memory" (
          let
            ensure = cond: msg: lib.assertMsg cond "single-memory: ${msg}";
            homes = lib.attrValues config.flake.homeConfigurations;
            makiHomes = lib.filter (h: h.config.home.file ? ".config/maki/init.lua") homes;
            pro = config.flake.homeConfigurations."smores@smorespro".config;
          in
          toString (
            assert
              ensure (lib.all (
                h: h.config.home.activation ? claudeConfig
              ) homes) "every home merges Claude's settings"
              && ensure (makiHomes != [ ]) "no home runs maki"
              && ensure (lib.all (
                h: lib.hasInfix "memory = { enabled = false }" h.config.home.file.".config/maki/init.lua".text
              ) makiHomes) "maki's bundled memory is on somewhere"
              && ensure (pro.systemd.user.services ? cloudflared-memory) "smorespro has no memory tunnel forward";
            "ok"
          )
        );

        # Scrubbed at source for #386: agents read whatever the human can, so no host ships a CLI
        # whose local state is a credential store.
        no-scrubbed-tools = evalCheck "no-scrubbed-tools" (
          let
            scrubbed = [ "bitwarden-cli" ];
            offenders = lib.concatMap (
              home:
              map (p: "${home.config.home.username}: ${lib.getName p}") (
                lib.filter (p: lib.elem (lib.getName p) scrubbed) home.config.home.packages
              )
            ) (lib.attrValues config.flake.homeConfigurations);
          in
          toString (
            assert lib.assertMsg (offenders == [ ]) "no-scrubbed-tools: ${lib.concatStringsSep ", " offenders}";
            "ok"
          )
        );

        # The sweep must fail on a planted token and pass on a clean tree, without printing the value.
        secret-sweep =
          let
            sweep = lib.findFirst (
              p: lib.getName p == "secret-sweep"
            ) (throw "secret-sweep not in home.packages") scriptHome.config.home.packages;
          in
          pkgs.runCommand "secret-sweep-check" { } ''
            mkdir -p clean dirty
            echo 'nothing to see' > clean/notes.txt
            # Assembled at build time so this file never holds a token-shaped literal.
            printf 'GITHUB_TOKEN=ghp_%s\n' "$(printf 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8' )" > dirty/.env
            ${lib.getExe sweep} clean
            if ${lib.getExe sweep} dirty > report.txt 2>&1; then
              echo "secret-sweep passed a planted token" >&2; exit 1
            fi
            grep -q 'dirty/.env' report.txt
            if grep -q 'A1b2C3d4E5f6' report.txt; then
              echo "secret-sweep printed the secret" >&2; exit 1
            fi
            # With no arguments it walks $HOME, skipping ~/Library only on Darwin.
            mkdir -p home/Library home/proj
            cp dirty/.env home/Library/.env
            cp clean/notes.txt home/proj/notes.txt
            ${
              if pkgs.stdenv.hostPlatform.isDarwin then
                "HOME=$PWD/home ${lib.getExe sweep}"
              else
                "! HOME=$PWD/home ${lib.getExe sweep} >/dev/null 2>&1"
            }
            touch $out
          '';

        # `claude-config` is built, not evaluated, so its script text is what is checked.
        claude-memory-off =
          pkgs.runCommand "claude-memory-off"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            }
            ''
              ${lib.concatMapStrings (
                home:
                let
                  tool = lib.findFirst (
                    p: lib.getName p == "claude-config"
                  ) (throw "claude-config is not installed") home.config.home.packages;
                in
                "grep -qF 'autoMemoryEnabled = false' ${lib.getExe tool}\n"
              ) homesHere}
              touch $out
            '';

        # The two memory instances share one description: only the personal one refuses work repos,
        # and the Mac instance reads its key from the sops path and extracts through Claude.
        memory-instances = evalCheck "memory-instances" (
          let
            ensure = cond: msg: lib.assertMsg cond "memory-instances: ${msg}";
            personal = config.flake.nixosConfigurations.smortress.config;
            work = config.flake.homeConfigurations."sam@smoreswork".config;
            envOf = pairs: lib.listToAttrs (map (p: lib.nameValuePair (lib.head p) (lib.last p)) pairs);
            personalWrapper = envOf (
              map (e: lib.splitString "=" e) personal.systemd.services.memory-mcp.serviceConfig.Environment
            );
            agents = work.launchd.agents;
            agentEnv = name: agents.${name}.config.EnvironmentVariables;
            argv = name: lib.concatStringsSep " " agents.${name}.config.ProgramArguments;
          in
          toString (
            assert
              ensure (
                personalWrapper.MEMORY_WORK_POLICY == "refuse"
              ) "the personal wrapper must refuse work repos"
              && ensure (
                (agentEnv "memory-mcp").MEMORY_WORK_POLICY == "allow"
              ) "the work wrapper accepts work repos"
              && ensure (
                !((agentEnv "memory-llm-proxy") ? MEMORY_LLM_REASONING_EFFORT)
              ) "the Mac proxy does not rewrite reasoning effort"
              && ensure (
                (agentEnv "memory-llm-proxy").MEMORY_LLM_CHAT_BACKEND == "claude"
              ) "the Mac extracts through headless Claude"
              && ensure (
                (agentEnv "memory-llm-proxy").MEMORY_LLM_PROXY_ALLOWED_HOSTS == "host.docker.internal"
              ) "the proxy admits the Docker Desktop host alias and nothing else"
              && ensure (
                (agentEnv "memory-llm-proxy").MEMORY_LLM_KEY_FILE == work.sops.secrets.openai-api-key.path
              ) "the proxy reads the key from its sops path"
              && ensure (
                !lib.hasInfix "--network=host" (
                  builtins.toJSON (lib.filterAttrs (n: _: lib.hasPrefix "memory-" n) agents)
                )
              ) "Docker Desktop has no host network"
              && ensure (lib.hasInfix "--keep 7" (argv "memory-export")) "the nightly export keeps seven dated copies"
              && ensure (
                agents.memory-export.config.StartCalendarInterval != [ ]
              ) "the nightly export is a calendar job"
              && ensure (!(work.sops.secrets ? neuralwatt-api-key)) "the Mac holds no personal provider key";
            "ok"
          )
        );

        # piv-ensure-proxy must pass arguments in order and use the cache dir the login wipe names;
        # a laptop's smortress proxy opts into the password fallback with an `env` prefix.
        piv-wiring =
          let
            laptop = lib.findFirst (h: !(builtins.elem "server" h.config.machine.profiles)) null homesHere;
            command = laptop.config.programs.ssh.settings.smortress.data.ProxyCommand;
            tangPi = laptop.config.programs.ssh.settings."tang-pi".data.ProxyCommand;
            args = lib.splitString " " command;
            proxy = lib.elemAt args (if lib.hasPrefix "env " command then 2 else 0);
            cache =
              if pkgs.stdenv.hostPlatform.isLinux then
                "\${XDG_RUNTIME_DIR:?}/piv"
              else
                "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)piv";
          in
          pkgs.runCommand "piv-wiring"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
              ];
            }
            ''
              test "$(echo ${lib.escapeShellArg command} | cut -d' ' -f1)" = env
              test "$(echo ${lib.escapeShellArg command} | cut -d' ' -f2)" = YK_ENSURE_PASSWORD_FALLBACK=1
              # The Pi is key-only; it must never carry the password opt-in.
              if echo ${lib.escapeShellArg tangPi} | grep -qF YK_ENSURE_PASSWORD_FALLBACK; then
                echo "tang-pi must stay PIV-only" >&2
                exit 1
              fi
              tr -d '\\\n' <${proxy} | grep -F 'piv-ensure.sh "' | grep -F 'opensc-pkcs11.so" "${cache}"' |
                grep -E 'piv-dialog +/nix/store/[^ ]+-piv-cache-askpass +/nix/store/[^ ]+-piv-k1.pub'
              touch $out
            '';

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

        # An outer interactive SSH login publishes its forwarded socket (OpenSSH >= 10.1: ~/.ssh/agent, older: /tmp);
        # a pty-less connection or a pane already holding the alias must leave it alone.
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

        # Linger starts the user manager at boot, so a default.target unit wanting graphical-session.target
        # raises the desktop at the greeter and niri.service starts outside niri-session. Noctalia must
        # not want niri.service: only niri-session may launch the compositor.
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
              # The pubkey derivation writes exactly keys.piv; this input would have to change for a FIDO2 signing.pub.
              if printf '%s\n' ${
                lib.escapeShellArgs (map (k: k.key) keys.piv)
              } | grep -qxE 'k[0-9]+/signing'; then exit 1; fi
              test ${toString (builtins.length keys.sudo)} -eq 3
              test "${names keys.piv}" = "piv-k1 piv-k2 piv-k3"
              test "${names keys.sudo}" = "k1/sudo k2/sudo k3/sudo"
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
              # harvest tests pin TZ=America/New_York; without zoneinfo the sandbox falls back to UTC.
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
              bash -n ${src}/tests/claude_config.sh
              shellcheck ${src}/tests/claude_config.sh
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
      # Evaluating the home does not run `niri validate`; building the rendered config does.
      //
        lib.optionalAttrs
          (config.flake.homeConfigurations."smores@smorespro".activationPackage.system == system)
          {
            niri-config =
              config.flake.homeConfigurations."smores@smorespro".config.xdg.configFile.niri-config.source;
          }
      # The Mac agent VM launcher as built: its ssh must never pick up the host's identities,
      # forwards or config, and the deny list must reach the planner (sdlc #386).
      //
        lib.optionalAttrs
          (config.flake.homeConfigurations."sam@smoreswork".activationPackage.system == system)
          {
            agent-vm-static =
              let
                launcher = lib.getExe (
                  lib.findFirst (p: lib.getName p == "agent-sandbox") (throw "agent-sandbox not on the work Mac")
                    config.flake.homeConfigurations."sam@smoreswork".config.home.packages
                );
              in
              pkgs.runCommand "agent-vm-static-check" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
                for opt in '-F /dev/null' 'IdentitiesOnly=yes' 'IdentityAgent=none' 'ForwardAgent=no' \
                  'PKCS11Provider=none' 'PermitLocalCommand=no' 'ProxyCommand=none' 'ControlPath=none' \
                  'ExitOnForwardFailure=yes' 'deny=(Library .config/sops' '@sha256:'; do
                  grep -qF -- "$opt" ${launcher} || { echo "agent-vm launcher lacks: $opt" >&2; exit 1; }
                done
                # Tart's --ssh forwards the host agent into the guest.
                if grep -qE 'tart run[^#]*--ssh' ${launcher}; then exit 1; fi
                if grep -qE '^[^#]*ssh [^"]*-A( |$)' ${launcher}; then exit 1; fi
                touch $out
              '';
          }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # The jupyter interpreter is the one bwrap profile left.
        jupyter-sandbox-static =
          pkgs.runCommand "jupyter-sandbox-static-check"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            }
            ''
              grep -F -- '--clearenv' ${../lib/jupyter-sandbox.sh}
              grep -F -- '--unshare-pid' ${../lib/jupyter-sandbox.sh}
              grep -F -- '--unshare-user' ${../lib/jupyter-sandbox.sh}
              grep -F -- '--tmpfs /run' ${../lib/jupyter-sandbox.sh}
              grep -F -- '/var/lib/data/photos' ${../lib/jupyter-sandbox.nix}
              touch $out
            '';
        agent-vm-linux-static =
          let
            hosts = map (n: config.flake.nixosConfigurations.${n}.config) [
              "smortress"
              "smorespro"
            ];
            facts =
              host:
              let
                guest = host.microvm.vms.agent.config.config;
                shares = guest.microvm.shares;
                home = "/home/${host.machine.username}";
              in
              {
                squash = lib.all (a: lib.elem a guest.microvm.virtiofsd.extraArgs) [
                  "--translate-uid=squash-guest:0:1000:4294967295"
                  "--translate-gid=squash-guest:0:100:4294967295"
                  "--modcaps=-mknod"
                ];
                noXattr = lib.all (sh: !sh.posixAcl) shares;
                # The home reaches the guest only through the assembled view.
                noRawHome = lib.all (sh: sh.source != home && !(lib.hasPrefix "${home}/" sh.source)) shares;
                guestBuilds = guest.microvm.writableStoreOverlay != null;
                keyOnly =
                  !guest.services.openssh.settings.PasswordAuthentication
                  && !guest.services.openssh.settings.AllowAgentForwarding
                  && guest.services.openssh.authorizedKeysFiles == [ "/run/secrets/agent-vm-authorized-keys" ];
                denies = lib.all (d: lib.elem d host.agentVm.deny) [
                  ".config/sops"
                  ".local/share/keyrings"
                  ".local/share/ykman"
                  ".local/state/key-backup"
                  ".config/BraveSoftware"
                  ".config/mozilla"
                  ".mozilla"
                  ".config/Bitwarden"
                  ".cache/cliphist"
                  ".gnupg"
                  "Vault"
                ];
                # A writable entry must never cover host-executed config or a denied path.
                narrowRw = lib.all (
                  r:
                  !(lib.elem r [
                    ""
                    "."
                    ".config"
                    ".local"
                    ".local/bin"
                    ".cache"
                    ".ssh"
                  ])
                  && lib.all (d: !(lib.hasPrefix "${r}/" d) && d != r) host.agentVm.deny
                ) host.agentVm.rw;
                firewall = host.networking.firewall.extraCommands;
              };
            all = map facts hosts;
            ok = lib.all (
              f: f.squash && f.noXattr && f.noRawHome && f.guestBuilds && f.keyOnly && f.denies && f.narrowRw
            ) all;
            launcher = (import ../lib/agent-vm.nix { inherit pkgs lib; }).launcher "smores";
          in
          assert lib.assertMsg ok
            "agent-vm: a Linux guest lost uid squashing, the view, guest builds, key-only sshd or a deny entry";
          pkgs.runCommand "agent-vm-linux-static-check"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
              firewall = lib.concatStrings (map (f: f.firewall) all);
              passAsFile = [ "firewall" ];
            }
            ''
              grep -F -- '-I INPUT 1 -i vm-agent -j agent-vm-in' "$firewallPath"
              if grep -F -- '-D INPUT' "$firewallPath"; then exit 1; fi
              rules4=$(grep -o '/nix/store/[^ ]*-agent-vm-rules4' "$firewallPath" | head -1)
              rules6=$(grep -o '/nix/store/[^ ]*-agent-vm-rules6' "$firewallPath" | head -1)
              grep -xF -- '-A agent-vm-in -j DROP' "$rules4"
              grep -xF -- '-A agent-vm-in -j DROP' "$rules6"
              grep -xF -- '-A agent-vm-fwd -j DROP' "$rules6"
              grep -xF -- '-A agent-vm-fwd -d 192.168.0.0/16 -j DROP' "$rules4"
              grep -xF -- '-A agent-vm-fwd -d 127.0.0.0/8 -j DROP' "$rules4"
              # The private-range drops come before the egress accept.
              [ "$(grep -n -- '-d 10.0.0.0/8 -j DROP' "$rules4" | cut -d: -f1)" -lt "$(grep -n -- '-A agent-vm-fwd -j ACCEPT' "$rules4" | cut -d: -f1)" ]
              # The forced key that lands laptop agents in this host's guest.
              grep -F -- 'no-user-rc' ${../nixos/ssh.nix}
              if grep -F -- 'no-touch-required' ${../nixos/ssh.nix}; then exit 1; fi
              l=${launcher}/bin/agent-sandbox
              for opt in '-F /dev/null' IdentitiesOnly=yes IdentityAgent=none ForwardAgent=no \
                PKCS11Provider=none PermitLocalCommand=no ProxyCommand=none ControlPath=none ClearAllForwardings=yes; do
                grep -F -- "$opt" "$l"
              done
              if grep -qE '^[^#]*ssh [^"]*-A( |$)' "$l"; then exit 1; fi
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
              grep -Fx 'AuthenticationMethods any' settings
              grep -Fx 'pubkeyauthoptions verify-required' settings
              grep -Fx 'PasswordAuthentication yes' settings
              grep -Fx 'KbdInteractiveAuthentication no' settings
              grep -Fx 'UsePAM yes' settings
              grep -Fx 'PermitRootLogin no' settings
              grep -Fx 'PermitEmptyPasswords no' settings
              grep -Fx 'AllowTcpForwarding no' settings
              grep -Fx 'AllowStreamLocalForwarding no' settings
              grep -Fxi 'streamlocalbindunlink no' settings
              grep -Fx 'AllowAgentForwarding yes' settings
              grep -Fx 'AllowUsers smores' settings
              grep -Fx 'PermitUserRC no' settings
              grep -Fx 'MaxAuthTries 10' settings
              grep -Fx 'LoginGraceTime 60' settings
              if grep -q '^AuthorizedKeysFile .*\.ssh/authorized_keys' settings; then exit 1; fi
              grep -q '^listenaddress 127\.0\.0\.1:' settings
              touch $out
            '';

        # A wrongly skipped jump, falling-through control or misplaced probe silently changes the accepted
        # credential. A failing pam_exec probe returns SYSTEM_ERR; under default=ignore the gate is skipped,
        # and only pam_p11's authinfo_unavail=ignore keeps that from locking the password out.
        pam-auth-gates =
          let
            cfg = config.flake.nixosConfigurations.smorespro.config;
            server = config.flake.nixosConfigurations.smortress.config;
            rendered =
              service: pkgs.writeText "pam-${service}.rendered" cfg.security.pam.services.${service}.text;
            serverRendered =
              service:
              pkgs.writeText "pam-server-${service}.rendered" server.security.pam.services.${service}.text;
            expected =
              name: lines: pkgs.writeText "pam-${name}.expected" (lib.concatStringsSep "\n" lines + "\n");
            # One line per auth rule: control, module basename, args with store paths reduced to basenames
            # (pins order and probe placement independent of store hashes).
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

              # The greeter is password-only: no fingerprint, smartcard or gate
              # may run before pam_unix.
              normalize ${rendered "greetd"} > greetd.stack
              diff -u ${
                expected "greetd" [
                  "sufficient pam_unix.so likeauth nullok try_first_pass"
                  "required pam_deny.so"
                ]
              } greetd.stack
              ! grep -qE 'pam_(p11|fprintd|exec)\.so' greetd.stack

              normalize ${rendered "login"} > login.stack
              diff -u ${
                expected "login" [
                  "[success=1 default=ignore] pam_exec.so quiet quiet_log pam-ccid-absent"
                  "[success=done authinfo_unavail=ignore default=die] pam_p11.so opensc-pkcs11.so ^[0-9]{8}$"
                  "sufficient pam_unix.so likeauth nullok try_first_pass"
                  "required pam_deny.so"
                ]
              } login.stack

              # smortress's sshd carries the password fallback: pam_unix, then deny, nothing in front.
              normalize ${serverRendered "sshd"} > sshd.stack
              diff -u ${
                expected "sshd" [
                  "sufficient pam_unix.so likeauth try_first_pass"
                  "required pam_deny.so"
                ]
              } sshd.stack
              ! grep -qE 'pam_(p11|fprintd|exec|rssh)\.so' ${serverRendered "sshd"}

              # A relative or missing probe is SYSTEM_ERR; for the card gate pam_p11 would then run unguarded.
              probes ${rendered "login"} > login.probes
              test "$(wc -l < login.probes)" -eq 1
              for p in $(cat login.probes); do test -x "$p"; done

              # A stray global p11/fprintd option would put a PIN-or-nothing module in front of sudo and every admin prompt.
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
