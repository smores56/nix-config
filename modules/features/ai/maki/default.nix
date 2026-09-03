{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) neuralwatt smortress;

  # All providers are written on every host; each provider script's has_auth
  # check reports availability based on which credential env vars are present,
  # so maki only offers providers that actually have auth on that machine.

  # init.lua is a Lua script that calls maki.setup() once, then loads custom
  # tools. always_yolo skips permission prompts (deny rules still apply);
  # always_thinking forces the max reasoning-effort level so the bundled
  # deepseek provider sends reasoning_effort="max" (deepseek only accepts
  # "max"; other providers snap to their dialect's ceiling). bash is off by
  # default in maki, so enable it for the coding-agent toolset.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    maki.setup({
      always_yolo = true,
      always_thinking = "max",
      plugins = {
        bash = { enabled = true },
      },
    })

    require("spawn_session")
    require("resume_session")
  '';

  # Permissions manifest for the Lua plugins under ./lua. `run` is needed by
  # spawn_session's maki.fn.jobstart (process spawn).
  pluginToml = ''
    [permissions]
    run = true
  '';

  # Custom providers for maki. Model catalogs and pricing live in providers.nix
  # and are projected into maki's shape via each provider's makiModels
  # attribute. displayName is maki-specific.
  providersToWrite = {
    ${smortress.providerId} = {
      displayName = "Qwen3.8 uncensored (smortress)";
      inherit (smortress) baseUrl keyEnv;
      models = smortress.makiModels;
    };
    ${neuralwatt.providerId} = {
      displayName = "Neuralwatt";
      inherit (neuralwatt) baseUrl keyEnv;
      models = neuralwatt.makiModels;
    };
  };

  mkProviderScript =
    p:
    let
      hasKey = p.keyEnv != null;
      # has_auth requires every credential env var to be non-empty.
      authEnvs = [ p.keyEnv ];
      authCheck = lib.concatMapStringsSep " && " (e: ''[ -n "''${${e}:-}" ]'') authEnvs;
      tailnetOnly = p.tailnetOnly or false;
      gateHost = builtins.head (lib.splitString ":" (lib.removePrefix "http://" p.baseUrl));
      infoCmd =
        if hasKey then
          ''
            if ${authCheck}; then ha=true; else ha=false; fi
            printf '{"display_name":%s,"base":"llama-cpp","has_auth":%s}\n' ${lib.escapeShellArg (builtins.toJSON p.displayName)} "$ha"''
        else if tailnetOnly then
          ''
                        if ${pkgs.python3}/bin/python3 -c 'import ipaddress,socket,sys
            try:
                sys.exit(0 if ipaddress.ip_address(socket.gethostbyname("${gateHost}")) in ipaddress.ip_network("100.64.0.0/10") else 1)
            except OSError:
                sys.exit(1)'; then ha=true; else ha=false; fi
                        printf '{"display_name":%s,"base":"llama-cpp","has_auth":%s}\n' ${lib.escapeShellArg (builtins.toJSON p.displayName)} "$ha"''
        else
          ''printf '%s\n' ${
            lib.escapeShellArg (
              builtins.toJSON {
                display_name = p.displayName;
                base = "llama-cpp";
                has_auth = true;
              }
            )
          }'';
      resolveCmd =
        if !hasKey then
          ''printf '%s\n' ${
            lib.escapeShellArg (
              builtins.toJSON {
                base_url = p.baseUrl;
                headers = { };
              }
            )
          }''
        else
          ''printf '{"base_url":%s,"headers":{"Authorization":"Bearer %s"}}\n' ${lib.escapeShellArg (builtins.toJSON p.baseUrl)} "''${${p.keyEnv}:-}"'';
    in
    ''
      #!/usr/bin/env bash
      # Managed by home-manager (modules/features/ai/maki). Manual edits are
      # clobbered.
      set -euo pipefail
      case "''${1:-}" in
        info)
          ${infoCmd}
          ;;
        models)
          printf '%s\n' ${lib.escapeShellArg (builtins.toJSON p.models)}
          ;;
        resolve)
          ${resolveCmd}
          ;;
      esac
    '';
  # Deny rules apply even under always_yolo — deny is consulted before
  # yolo (yolo only skips prompting). Catastrophic-pattern backstop against
  # a compromised model or prompt injection; not a sandbox — obfuscated
  # forms can slip through.
  permissionsToml = ''
    [bash]
    deny = [
      "sudo",
      "sudo *",
      "rm -rf /",
      "rm -rf /*",
      "rm -fr /",
      "rm -fr /*",
      "rm -rf ~",
      "rm -rf ~/*",
      "rm -rf $HOME",
      "rm -rf $HOME/*",
      "sh",
      "bash",
      "git push --force *",
      "git push -f *",
      "git push * --force *",
      "dd of=/dev/*",
      "dd * of=/dev/*",
      "mkfs*",
      "mkfs *",
    ]
  '';

  makiSessionSearch = "${pkgs.python3}/bin/python3 ${./maki-session-search.py}";
  # PATH bin so the maki Lua plugin can invoke it by name via maki.fn.jobstart.
  makiSessionSearchBin = pkgs.writeShellScriptBin "maki-session-search" ''
    exec ${pkgs.python3}/bin/python3 ${./maki-session-search.py} "$@"
  '';
  makiSessionCable = pkgs.writers.writeTOML "maki-sessions.toml" {
    metadata = {
      name = "maki-sessions";
      description = "Maki session history";
      requirements = [ "maki" ];
    };
    source = {
      command = "${makiSessionSearch} list";
      display = "{split: :1..}";
      output = "{split: :0}";
    };
    preview.command = "${makiSessionSearch} show {split: :0}";
  };

in
{
  config = {
    home.file = {
      ".config/maki/init.lua" = {
        force = true;
        text = initLua;
      };
      ".config/maki/plugin.toml" = {
        force = true;
        text = pluginToml;
      };
      ".config/maki/permissions.toml" = {
        force = true;
        text = permissionsToml;
      };
      ".config/maki/AGENTS.md" = {
        force = true;
        text = ''
          ${config.dotfiles.aiHints}
          # Delegation
          For the top-level coordinator — subagents execute their assignment
          directly. You are a workflow manager: delegate implementation by
          default; handle directly only what is faster to do than describe.

          ## Lanes (subagent_type follows permissions)
          - explorer (research): codebase recon — not when you know the path or are about to edit
          - librarian (research): external docs, API refs, version-specific behavior
          - oracle (research): architecture, risk, complex debugging, review — not for routine fixes
          - fixer (general): bounded execution — research first if it needs discovery

          ## Rules
          - Missing context? Run a read-only research lane first, then inline
            findings into the dependent fixer prompt — every task starts fresh
            (paths, constraints, acceptance criteria); ask for file:line
            summaries, not code dumps
          - Parallelize independent lanes; serialize writers sharing files or
            the dotfiles.* contract
          - Acceptance criteria: behavioral for implementation, evidence for research
          - The coordinator verifies — narrowest relevant validation first,
            broaden only on failed focused checks
        '';
      };

      ".config/maki/lua/spawn_session.lua" = {
        force = true;
        source = ./lua/spawn_session.lua;
      };
      ".config/maki/lua/resume_session.lua" = {
        force = true;
        source = ./lua/resume_session.lua;
      };
      ".config/television/cable/maki-sessions.toml".source = makiSessionCable;
    }
    // lib.optionalAttrs (providersToWrite != { }) (
      lib.mapAttrs' (
        slug: p:
        lib.nameValuePair ".config/maki/providers/${slug}" {
          force = true;
          executable = true;
          text = mkProviderScript p;
        }
      ) providersToWrite
    );
    home.packages = [
      pkgs.rtk
      makiSessionSearchBin
    ];
    programs.fish = {
      functions.__maki_session_resume = {
        body = ''
          set -l session_id $argv[1]
          set -l cwd (${makiSessionSearch} cwd "$session_id")
          if not test -d "$cwd"
            printf 'maki session directory no longer exists: %s\n' "$cwd" >&2
            return 1
          end
          cd "$cwd"
          command maki --session "$session_id"
        '';
      };
      shellAbbrs.ms = "tv maki-sessions | read -l s; and __maki_session_resume $s";
    };
  };
}
