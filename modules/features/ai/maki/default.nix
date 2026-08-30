{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) neuralwatt cloudflare smortress;

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

  mcpServers = config.dotfiles.ai.mcpServers;
  shellQuote = lib.escapeShellArg;
  # An env value that is exactly a ${VAR} reference expands at runtime (the
  # wrapper runs through sh -lc); anything else is a literal. Single-quoting
  # a ${VAR} value would pass the literal string to the server.
  isEnvRef = value: builtins.match "\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}" value != null;
  mkEnvExport = name: value:
    if isEnvRef value then "export ${name}=\"${value}\"" else "export ${name}=${shellQuote value}";
  mkMakiMcpServer =
    server:
    let
      args = server.args or [ ];
      command = server.command;
      commandList = if builtins.isList command then command else [ command ] ++ args;
      env = server.env or { };
      envExports = lib.concatStringsSep "\n" (lib.mapAttrsToList mkEnvExport env);
      execCommand = lib.concatMapStringsSep " " shellQuote commandList;
    in
    removeAttrs server [ "args" ]
    // {
      command =
        if env == { } then
          commandList
        else
          [
            "sh"
            "-lc"
            ''
              ${envExports}
              exec ${execCommand}
            ''
          ];
    };
  makiMcpServers = lib.mapAttrs (_: mkMakiMcpServer) mcpServers;
  mcpToml = pkgs.writers.writeTOML "maki-mcp.toml" { mcp = makiMcpServers; };

  # Custom providers for maki. Model catalogs and pricing live in providers.nix
  # and are projected into maki's shape via each provider's makiModels
  # attribute. displayName is maki-specific.
  providersToWrite = {
    ${smortress.providerId} = {
      displayName = "Qwen3.8 uncensored (smortress)";
      baseUrl = smortress.baseUrl;
      keyEnv = smortress.keyEnv;
      models = smortress.makiModels;
    };
    ${neuralwatt.providerId} = {
      displayName = "Neuralwatt";
      baseUrl = neuralwatt.baseUrl;
      keyEnv = neuralwatt.keyEnv;
      models = neuralwatt.makiModels;
    };
    ${cloudflare.providerId} = {
      displayName = "Cloudflare Workers AI";
      baseUrl = cloudflare.makiBaseUrl;
      keyEnv = cloudflare.keyEnv;
      extraAuthEnv = cloudflare.extraAuthEnv;
      dynamicBaseUrl = true;
      models = cloudflare.makiModels;
    };
  };

  mkProviderScript =
    p:
    let
      hasKey = p.keyEnv != null;
      # has_auth requires every credential env var (the key plus any extras, e.g.
      # Cloudflare's account id) to be non-empty.
      authEnvs = [ p.keyEnv ] ++ (p.extraAuthEnv or [ ]);
      authCheck = lib.concatMapStringsSep " && " (e: ''[ -n "''${${e}:-}" ]'') authEnvs;
      dynamicBaseUrl = p.dynamicBaseUrl or false;
      infoCmd =
        if hasKey then
          ''
            if ${authCheck}; then ha=true; else ha=false; fi
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
        else if dynamicBaseUrl then
          # baseUrl carries shell ''${VAR} refs expanded by bash at runtime.
          ''printf '{"base_url":"%s","headers":{"Authorization":"Bearer %s"}}\n' "${p.baseUrl}" "''${${p.keyEnv}:-}"''
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
  # maki's OpenAI login is device-code, blocked by the work ChatGPT workspace;
  # standard Codex browser login works. Mirror Codex's OAuth token into maki's
  # store on switch and on demand (`maki-codex-sync`). No-op when Codex has no
  # ChatGPT credential. Work Mac only.
  codexCredSync = pkgs.writeShellScriptBin "maki-codex-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./codex-cred-sync.py}
  '';

  # maki stores per-session token counts but never the dollar cost, and has no
  # cross-session rollup. maki-cf-cost scans the session JSONL logs and reports
  # Cloudflare Workers AI spend per month. Pricing is generated from the
  # cloudflare provider in providers.nix (cfPricingJson) so the report never
  # duplicates the pricing table.
  cfPricingJson = pkgs.writeText "maki-cf-pricing.json" (
    builtins.toJSON (
      builtins.listToAttrs (
        map (
          m:
          lib.nameValuePair m.id {
            input = m.pricing.input;
            output = m.pricing.output;
            cache_read = m.pricing.cache_read;
          }
        ) cloudflare.makiModels
      )
    )
  );
  cfCostReport = pkgs.writeShellScriptBin "maki-cf-cost" ''
    MAKI_CF_PRICING=${cfPricingJson} exec ${pkgs.python3}/bin/python3 ${./cf-cost-report.py} "$@"
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
      ".config/maki/AGENTS.md" = {
        force = true;
        text = ''
          ${config.dotfiles.aiHints}
          # Delegation
          This guidance is for the top-level coordinator (you, working with the user). If
          you were spawned as a subagent, execute your assignment directly — do not
          delegate further.

          You are a workflow manager, not the default implementation worker. Default to
          delegating implementation to a general (fixer) subagent; handle directly only a
          trivial edit faster to make than describe. Split non-trivial work into lanes; if
          it won't split, delegate as one fixer task.

          ## Lanes
          subagent_type follows permissions. Choose the lane based on task complexity and risk.
          - explorer (research): codebase recon — glob/grep/index. Use for structural or
            ambiguous queries; do not use when you know the path or are about to edit.
          - librarian (research): external docs, API refs, version-specific behavior.
          - oracle (research): architecture, risk, complex debugging, review, simplification.
            Do not use for routine or first bug-fix attempts.
          - fixer (general): bounded execution — bounded target reads, no open-ended
            research/design. Research first (explorer/librarian/oracle) if it needs discovery.

          ## Process

          - Missing context for a lane? Run a read-only research task first, then inline
            findings into the dependent fixer prompt.
          - Parallelize independent lanes in batch; run dependent ones sequentially.
          - Parallel writers only when file sets are disjoint and share no dotfiles.*
            contract; serialize any overlap.
          - output_schema only for read-only results you'll mechanically reconcile. For
            write tasks the working-tree diff is the result; inspect before retrying.
          - Synthesize, resolve conflicts, verify, deliver.


          ## Discipline
          - State acceptance criteria where determinable: behavioral for implementation,
            evidence/coverage for research.
          - Every task starts fresh: inline paths, constraints, expected output, edit
            permission, prior findings, and acceptance criteria. Ask for concise file:line
            summaries, not code dumps.
          - Brief delegation notices, no flattery, honest pushback when an approach is wrong.
          - Verify: narrowest relevant validation first; broaden only when scope, risk, or a
            failed focused check justifies it. The coordinator runs final verification.
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
    // lib.optionalAttrs (mcpServers != { }) {
      ".config/maki/mcp.toml" = {
        force = true;
        source = mcpToml;
      };
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
      codexCredSync
      cfCostReport
    ];
    home.activation.makiCodexCreds = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${codexCredSync}/bin/maki-codex-sync || true
    '';
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
