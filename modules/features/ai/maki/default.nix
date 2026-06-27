{
  config,
  lib,
  pkgs,
  aiXiaomi,
  ...
}:
let
  cfg = config.dotfiles.maki;
  workModels = config.dotfiles.workModels;
  # When set, install Cloudflare Workers AI as an additional custom provider.
  # It is intentionally never the generated default; the work machine defaults
  # to Codex-backed OpenAI, and personal hosts keep their normal Xiaomi default.
  cfEnabled = cfg.cloudflareWorkersAi.enable;

  # Work: Codex-backed GPT-5.5 via Maki's built-in `openai` provider, whose
  # OAuth creds are mirrored from Codex CLI by maki-codex-sync below. The rest
  # of the Codex cascade stays selectable in Maki's built-in catalog:
  # strong = openai/gpt-5.5, medium = openai/gpt-5.4, weak = openai/gpt-5.4-mini.
  # Personal hosts keep Xiaomi MiMo Pro as the default.
  defaultModel =
    if workModels then "openai/gpt-5.5" else "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25Pro.id}";

  makiTools = [
    "bash = { enabled = true }"
    "memory = { enabled = false }"
  ];
  toolsBlock = lib.concatMapStrings (t: "\n        " + t + ",") makiTools;

  # init.lua is a Lua script that calls maki.setup() once, then loads custom
  # tools. always_yolo skips permission prompts (deny rules still apply);
  # always_thinking turns on adaptive extended thinking. bash is off by default
  # in maki, so enable it to match oh-my-pi's coding-agent toolset.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    maki.setup({
      always_yolo = true,
      always_thinking = true,
      provider = {
        default_model = "${defaultModel}",
      },
      tools = {${toolsBlock}
      },
    })

    require("spawn_session")
  '';

  # Permissions manifest for the Lua plugins under ./lua. `run` is needed by
  # spawn_session's maki.fn.jobstart (process spawn).
  pluginToml = ''
    [permissions]
    run = true
  '';

  mcpServers = cfg.mcpServers;
  mcpToml = pkgs.writers.writeTOML "maki-mcp.toml" { mcp = mcpServers; };

  # mimo / gemma are OpenAI-compatible endpoints maki ships no built-in
  # for. maki discovers custom providers as executable scripts in
  # ~/.config/maki/providers/<slug> answering info/models/resolve. base
  # "llama-cpp" selects the plain OpenAI /v1 chat-completions dialect (no
  # Responses API / developer role) that all three speak; resolve injects the
  # bearer token and info's has_auth reflects whether the key env var is set, so
  # a provider only lights up when its creds are available. Personal hosts only;
  # work hosts drive Codex-backed OpenAI, with optional Cloudflare.
  makiProviders = {
    ${aiXiaomi.providerId} = {
      displayName = "Xiaomi MiMo";
      baseUrl = aiXiaomi.baseUrl;
      keyEnv = "XIAOMI_MIMO_API_KEY";
      models = [
        {
          id = aiXiaomi.models.mimoV25Pro.id;
          tier = "strong";
          context_window = aiXiaomi.models.mimoV25Pro.context;
          max_output_tokens = aiXiaomi.models.mimoV25Pro.output;
        }
        {
          id = aiXiaomi.models.mimoV25.id;
          tier = "weak";
          context_window = aiXiaomi.models.mimoV25.context;
          max_output_tokens = aiXiaomi.models.mimoV25.output;
        }
      ];
    };
    smortress = {
      displayName = "Gemma (smortress)";
      baseUrl = "http://smortress:8081/v1";
      keyEnv = null;
      models = [
        {
          id = "gemma-4-31b";
          tier = "medium";
          context_window = 102400;
          max_output_tokens = 102400;
        }
      ];
    };
    # Neuralwatt (https://portal.neuralwatt.com) — OpenAI-compatible inference with
    # energy-based pricing ($5/kWh flat). Energy benchmarks from portal models page;
    # actual billing is metered per-request. Token pricing is USD per 1M tokens (for
    # maki's per-session cost readout; actual billing is energy-based). Context and
    # pricing from https://portal.neuralwatt.com/models. Ordering matters: maki's
    # dynamic provider lookup uses starts_with prefix matching with first-match-wins,
    # so longer/suffixed ids (e.g. glm-5.2-short) must precede their prefix (glm-5.2).
    # Tiers track active MoE parameters per token (proxy for per-token capability):
    #   strong  = GLM-5.2 (744B/40B active), Kimi K2.6/K2.7 (1T/32B active)
    #   medium  = Qwen3.5-397B (397B/17B active)
    #   weak    = Qwen3.6-35B (35B/3B active)
    # Fast/short variants share their base model's weights, so they inherit its tier.
    neuralwatt = {
      displayName = "Neuralwatt";
      baseUrl = "https://api.neuralwatt.com/v1";
      keyEnv = "NEURALWATT_API_KEY";
      models = [
        {
          id = "glm-5.2-short-fast";
          tier = "strong";
          context_window = 200000;
          max_output_tokens = 32768;
          pricing = {
            input = 1.45;
            output = 4.50;
            cache_write = 0.0;
            cache_read = 0.36;
          };
        }
        {
          id = "glm-5.2-short";
          tier = "strong";
          context_window = 200000;
          max_output_tokens = 32768;
          pricing = {
            input = 1.45;
            output = 4.50;
            cache_write = 0.0;
            cache_read = 0.36;
          };
        }
        {
          id = "glm-5.2-fast";
          tier = "strong";
          context_window = 1048576;
          max_output_tokens = 32768;
          pricing = {
            input = 1.45;
            output = 4.50;
            cache_write = 0.0;
            cache_read = 0.36;
          };
        }
        {
          id = "glm-5.2";
          tier = "strong";
          context_window = 1048576;
          max_output_tokens = 32768;
          pricing = {
            input = 1.45;
            output = 4.50;
            cache_write = 0.0;
            cache_read = 0.36;
          };
        }
        {
          id = "kimi-k2.6-fast";
          tier = "strong";
          context_window = 262144;
          max_output_tokens = 32768;
          pricing = {
            input = 0.69;
            output = 3.22;
            cache_write = 0.0;
            cache_read = 0.0;
          };
        }
        {
          id = "kimi-k2.6";
          tier = "strong";
          context_window = 262144;
          max_output_tokens = 32768;
          pricing = {
            input = 0.69;
            output = 3.22;
            cache_write = 0.0;
            cache_read = 0.0;
          };
        }
        {
          id = "kimi-k2.7-code";
          tier = "strong";
          context_window = 262144;
          max_output_tokens = 32768;
          pricing = {
            input = 0.95;
            output = 4.00;
            cache_write = 0.0;
            cache_read = 0.0;
          };
        }
        {
          id = "qwen3.5-397b-fast";
          tier = "medium";
          context_window = 262144;
          max_output_tokens = 32768;
          pricing = {
            input = 0.69;
            output = 4.14;
            cache_write = 0.0;
            cache_read = 0.17;
          };
        }
        {
          id = "qwen3.5-397b";
          tier = "medium";
          context_window = 262144;
          max_output_tokens = 32768;
          pricing = {
            input = 0.69;
            output = 4.14;
            cache_write = 0.0;
            cache_read = 0.17;
          };
        }
        {
          id = "qwen3.6-35b-fast";
          tier = "weak";
          context_window = 131072;
          max_output_tokens = 16384;
          pricing = {
            input = 0.29;
            output = 1.15;
            cache_write = 0.0;
            cache_read = 0.07;
          };
        }
        {
          id = "qwen3.6-35b";
          tier = "weak";
          context_window = 131072;
          max_output_tokens = 16384;
          pricing = {
            input = 0.29;
            output = 1.15;
            cache_write = 0.0;
            cache_read = 0.07;
          };
        }
      ];
    };
  };

  # Cloudflare Workers AI via its OpenAI-compatible endpoint
  # (.../ai/v1/chat/completions; the @cf/... model id rides in the request body,
  # the documented equivalent of the /ai/run/<model> REST path). The account id
  # is interpolated into base_url at runtime (dynamicBaseUrl), and both the
  # account id and token must be present for the provider to light up. Tiers map
  # strong/medium/weak -> glm-5.2 / gpt-oss-120b / glm-4.7-flash. pricing is USD
  # per 1M tokens (drives maki's live per-session cost readout and the
  # maki-cf-cost monthly rollup — keep in sync with cf-cost-report.py).
  cloudflareProviders.cloudflare = {
    displayName = "Cloudflare Workers AI";
    baseUrl = "https://api.cloudflare.com/client/v4/accounts/\${CLOUDFLARE_ACCOUNT_ID}/ai/v1";
    keyEnv = "CLOUDFLARE_WORKERS_AI_API_TOKEN";
    extraAuthEnv = [ "CLOUDFLARE_ACCOUNT_ID" ];
    dynamicBaseUrl = true;
    models = [
      {
        id = "@cf/zai-org/glm-5.2";
        tier = "strong";
        context_window = 131072;
        max_output_tokens = 32768;
        pricing = {
          input = 1.40;
          output = 4.40;
          cache_write = 0.0;
          cache_read = 0.0;
        };
      }
      {
        id = "@cf/openai/gpt-oss-120b";
        tier = "medium";
        context_window = 128000;
        max_output_tokens = 32768;
        pricing = {
          input = 0.35;
          output = 0.75;
          cache_write = 0.0;
          cache_read = 0.0;
        };
      }
      {
        id = "@cf/zai-org/glm-4.7-flash";
        tier = "weak";
        context_window = 131072;
        max_output_tokens = 16384;
        pricing = {
          input = 0.06;
          output = 0.40;
          cache_write = 0.0;
          cache_read = 0.0;
        };
      }
    ];
  };

  providersToWrite =
    lib.optionalAttrs (!workModels) makiProviders // lib.optionalAttrs cfEnabled cloudflareProviders;

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
      #!${pkgs.bash}/bin/bash
      # Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
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
  # Cloudflare Workers AI spend per month, applying the same per-1M pricing as
  # cloudflareProviders above.
  cfCostReport = pkgs.writeShellScriptBin "maki-cf-cost" ''
    exec ${pkgs.python3}/bin/python3 ${./cf-cost-report.py} "$@"
  '';

in
{
  options.dotfiles.maki = {
    cloudflareWorkersAi.enable =
      lib.mkEnableOption "Cloudflare Workers AI as an extra maki provider"
      // {
        description = ''
          Install Cloudflare Workers AI as an extra selectable maki provider
          (GLM 5.2 strong / gpt-oss-120b medium / GLM 4.7 Flash weak) and the
          maki-cf-cost monthly spend report. This never changes the generated
          default model or disables Codex/OpenAI credential sync. Requires
          CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_WORKERS_AI_API_TOKEN in the
          environment.
        '';
      };
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        MCP server definitions written to ~/.config/maki/mcp.toml. Maki uses
        TOML sections under [mcp.<name>]; stdio servers use command arrays.
      '';
    };
  };

  config = {
    dotfiles.maki.mcpServers = {
      "basic-memory" = {
        command = [
          "uvx"
          "basic-memory"
          "mcp"
        ];
        env = {
          BASIC_MEMORY_SEMANTIC_SEARCH_ENABLED = "true";
          BASIC_MEMORY_SEMANTIC_EMBEDDING_PROVIDER = "fastembed";
        };
      };
    };

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
          # Delegation Decision Tree
          - Small, obvious work (single bounded task, no research needed): delegate with one `task` call, or wrap several
            independent ones in `batch`
          - Non-trivial work (multi-step, multi-file, ambiguous, risky, parallelizable, or requiring research): split into
            useful lanes first; if it won't split cleanly, do it directly rather than forcing delegation
          - For each lane, check context: missing? Run a read-only `task` with `subagent_type="research"` first
          - Then delegate the bounded implementation per lane: `task` with `subagent_type="general"`; parallelize independent
            calls in `batch`, run dependent ones sequentially
          - After delegation: synthesize results yourself, resolve conflicts, verify, deliver the integrated answer
          - Default `model_tier="medium"` for implementation, refactors, features, bug diagnosis, logic, anything needing
            real code judgment — most subtasks land here
          - Drop to `model_tier="weak"` when the task is mechanical and fully specified: search, grep, glob, reads,
            summaries, names, boilerplate edits, formatting, test runs
          - Reach for `model_tier="strong"` when the task is hard or high-stakes: architecture, system design, subtle or
            cross-file bugs, security review, irreversible changes, synthesizing conflicting subagent results
          - Every `task` starts fresh: include paths, constraints, expected output, and whether edits are allowed
          - Ask subagents for concise `file_path:line_number` summaries, not code dumps
        '';
      };

      ".config/maki/lua/spawn_session.lua" = {
        force = true;
        source = ./lua/spawn_session.lua;
      };
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
    home.packages = lib.optional workModels codexCredSync ++ lib.optional cfEnabled cfCostReport;
    home.activation.makiCodexCreds = lib.mkIf workModels (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${codexCredSync}/bin/maki-codex-sync || true
      ''
    );
  };
}
