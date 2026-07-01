{
  config,
  lib,
  pkgs,
  aiXiaomi,
  aiNeuralwatt,
  aiDeepseek,
  ...
}:
let
  cfg = config.dotfiles.smelt;
  workModels = config.dotfiles.workModels;
  # Cloudflare Workers AI is an extra provider, never the default. Work hosts
  # default to Codex-backed OpenAI; personal hosts keep Xiaomi MiMo Pro.
  cfEnabled = cfg.cloudflareWorkersAi.enable;

  # Work: Codex (ChatGPT subscription) registered via the `codex` provider type.
  # OAuth tokens live in $XDG_STATE_HOME/smelt/codex_auth.json after `smelt auth`,
  # so no api_key_env is needed. Personal hosts keep Xiaomi MiMo Pro as the default.
  defaultModel =
    if workModels then "codex/gpt-5.5" else "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25Pro.id}";

  # model.preferred helper-model overrides. Names are read by the bundled
  # plugins: title, compact, predict, btw, web_fetch. Each reference resolves
  # through the same provider/model lookup as the primary model, so the model
  # must be registered under a provider below.
  preferredBlock = ''
    smelt.model.preferred("title", "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}")
    smelt.model.preferred("compact", "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}")
    smelt.model.preferred("predict", "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}")
    smelt.model.preferred("btw", "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}")
    smelt.model.preferred("web_fetch", "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}")
  '';

  # Render one model entry's per-model override fields as a Lua table line.
  # Pricing fields are USD per 1M tokens (drives smelt's session cost readout).
  renderModel =
    m:
    let
      fields = [
        ''name = "${m.id}"''
      ]
      ++ lib.optional (m.context_window or null != null) "context_window = ${toString m.context_window}"
      ++ lib.optional (m.max_output_tokens or null != null) "max_tokens = ${toString m.max_output_tokens}"
      ++ (
        if m.pricing or null == null then
          [ ]
        else
          [
            "input_cost = ${toString m.pricing.input}"
            "output_cost = ${toString m.pricing.output}"
            "cache_read_cost = ${toString m.pricing.cache_read}"
            "cache_write_cost = ${toString m.pricing.cache_write}"
          ]
      );
    in
    "    { " + lib.concatStringsSep ", " fields + " },";

  # Render a smelt.provider.register(...) call for one provider.
  renderProvider =
    name: p:
    let
      headerFields = [
        ''type = "${p.type}"''
      ]
      ++ lib.optional (p.apiBase or null != null) ''api_base = "${p.apiBase}"''
      ++ lib.optional (p.apiKeyEnv or null != null) ''api_key_env = "${p.apiKeyEnv}"'';
      header = "    " + lib.concatStringsSep ", " headerFields + ",";
      models = lib.concatMapStrings (m: renderModel m + "\n") p.models;
    in
    ''
      smelt.provider.register("${name}", {
      ${header}
        models = {
      ${models}      },
      })
    '';

  # Personal Xiaomi provider (work hosts skip and use Codex).
  xiaomiProvider = {
    type = "openai-compatible";
    apiBase = aiXiaomi.baseUrl;
    apiKeyEnv = "XIAOMI_MIMO_API_KEY";
    models = [
      {
        id = aiXiaomi.models.mimoV25Pro.id;
        context_window = aiXiaomi.models.mimoV25Pro.context;
        max_output_tokens = aiXiaomi.models.mimoV25Pro.output;
      }
      {
        id = aiXiaomi.models.mimoV25.id;
        context_window = aiXiaomi.models.mimoV25.context;
        max_output_tokens = aiXiaomi.models.mimoV25.output;
      }
    ];
  };

  # Neuralwatt (https://portal.neuralwatt.com): OpenAI-compatible inference
  # with energy-based pricing. Token pricing is USD per 1M tokens (drives
  # smelt's session cost readout). Context/pricing from the portal models page.
  neuralwattProvider = {
    type = "openai-compatible";
    apiBase = aiNeuralwatt.baseUrl;
    apiKeyEnv = "NEURALWATT_API_KEY";
    models =
      let
        mk = id: ctx: out: pin: pout: cread: cwrite: {
          inherit id;
          context_window = ctx;
          max_output_tokens = out;
          pricing = {
            input = pin;
            output = pout;
            cache_read = cread;
            cache_write = cwrite;
          };
        };
      in
      [
        (mk "glm-5.2-short-fast" 200000 32768 1.45 4.50 0.36 0.0)
        (mk "glm-5.2-short" 200000 32768 1.45 4.50 0.36 0.0)
        (mk "glm-5.2-fast" 1048576 32768 1.45 4.50 0.36 0.0)
        (mk "glm-5.2" 1048576 32768 1.45 4.50 0.36 0.0)
        (mk "kimi-k2.6-fast" 262144 32768 0.69 3.22 0.0 0.0)
        (mk "kimi-k2.6" 262144 32768 0.69 3.22 0.0 0.0)
        (mk "kimi-k2.7-code" 262144 32768 0.95 4.00 0.0 0.0)
        (mk "qwen3.5-397b-fast" 262144 32768 0.69 4.14 0.17 0.0)
        (mk "qwen3.5-397b" 262144 32768 0.69 4.14 0.17 0.0)
        (mk "qwen3.6-35b-fast" 131072 16384 0.29 1.15 0.07 0.0)
        (mk "qwen3.6-35b" 131072 16384 0.29 1.15 0.07 0.0)
      ];
  };

  # DeepSeek (OpenAI-compatible, personal hosts only when used).
  deepseekProvider = {
    type = "openai-compatible";
    apiBase = aiDeepseek.baseUrl;
    apiKeyEnv = "DEEPSEEK_API_KEY";
    models = [
      {
        id = aiDeepseek.models.v4Pro.id;
        context_window = aiDeepseek.models.v4Pro.context;
        max_output_tokens = aiDeepseek.models.v4Pro.output;
      }
      {
        id = aiDeepseek.models.v4Flash.id;
        context_window = aiDeepseek.models.v4Flash.context;
        max_output_tokens = aiDeepseek.models.v4Flash.output;
      }
    ];
  };

  # Codex (ChatGPT subscription, OAuth-backed). No api_key_env: OAuth tokens
  # live in $XDG_STATE_HOME/smelt/codex_auth.json after `smelt auth`. smelt's
  # codex provider kind owns the api_base, so we omit it.
  codexProvider = {
    type = "codex";
    apiBase = null;
    apiKeyEnv = null;
    models = [ { id = "gpt-5.5"; } ];
  };

  # smortress (gemma, local network host). No key required.
  smortressProvider = {
    type = "openai-compatible";
    apiBase = "http://smortress:8081/v1";
    apiKeyEnv = null;
    models = [
      {
        id = "gemma-4-31b";
        context_window = 102400;
        max_output_tokens = 102400;
      }
    ];
  };

  # Cloudflare Workers AI via its OpenAI-compatible endpoint. NOTE: smelt's
  # provider config is static — it does not expand ${VAR} in api_base, and its
  # provider.middleware only rewrites responses, not requests. So unlike maki
  # (which builds the base URL at resolve time), the Cloudflare account id must
  # be baked into the URL. We read it from the CLOUDFLARE_ACCOUNT_ID option so
  # the module is still declarative; change the option, rebuild.
  cloudflareAccount = config.dotfiles.smelt.cloudflareWorkersAi.accountId;
  cloudflareProvider.cloudflare = {
    type = "openai-compatible";
    apiBase = "https://api.cloudflare.com/client/v4/accounts/${cloudflareAccount}/ai/v1";
    apiKeyEnv = "CLOUDFLARE_WORKERS_AI_API_TOKEN";
    models = [
      {
        id = "@cf/zai-org/glm-5.2";
        context_window = 131072;
        max_output_tokens = 32768;
        pricing = {
          input = 1.40;
          output = 4.40;
          cache_read = 0.0;
          cache_write = 0.0;
        };
      }
      {
        id = "@cf/openai/gpt-oss-120b";
        context_window = 128000;
        max_output_tokens = 32768;
        pricing = {
          input = 0.35;
          output = 0.75;
          cache_read = 0.0;
          cache_write = 0.0;
        };
      }
      {
        id = "@cf/zai-org/glm-4.7-flash";
        context_window = 131072;
        max_output_tokens = 16384;
        pricing = {
          input = 0.06;
          output = 0.40;
          cache_read = 0.0;
          cache_write = 0.0;
        };
      }
    ];
  };

  providers =
    lib.optionalAttrs (!workModels) {
      ${aiXiaomi.providerId} = xiaomiProvider;
      neuralwatt = neuralwattProvider;
      smortress = smortressProvider;
      deepseek = deepseekProvider;
    }
    // lib.optionalAttrs workModels { codex = codexProvider; }
    // lib.optionalAttrs cfEnabled cloudflareProvider;

  providerBlock = lib.concatMapStrings (name: renderProvider name providers.${name}) (
    lib.attrNames providers
  );

  # Render a Lua string: "value".
  luaStr = s: "\"${lib.escape [ "\"" ] (toString s)}\"";

  # Render a list of strings as a Lua list: { "a", "b" }.
  luaList = xs: "{ " + lib.concatStringsSep ", " (map luaStr xs) + " }";

  # Render an attrset as a Lua table body: { k = "v", k2 = "v2" }.
  luaTable =
    attrs:
    "{ " + lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k} = ${luaStr v}") attrs) + " }";

  # Render a smelt.mcp.register(...) call for one MCP server.
  renderMcp =
    name: s:
    let
      fields = [
        "command = ${luaList (s.command or [ ])}"
      ]
      ++ lib.optional (s.description or null != null) "description = ${luaStr s.description}"
      ++ lib.optional (s.env or null != null) "env = ${luaTable s.env}"
      ++ lib.optional (s.timeout or null != null) "timeout = ${toString s.timeout}";
    in
    ''
      smelt.mcp.register("${name}", {
        ${lib.concatStringsSep ", " fields},
      })
    '';

  mcpBlock = lib.concatMapStrings (name: renderMcp name mcpServers.${name}) (
    lib.attrNames mcpServers
  );

  inherit (cfg) mcpServers;

  # init.lua mirrors maki's setup intent. smelt has no always_yolo flag; Yolo
  # mode is the equivalent (all tools auto-allow; deny rules still apply).
  # always_thinking maps to a high reasoning_effort default. vim and
  # auto_compact are settings. spawn_session.lua is required at the end.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/smelt). Manual edits are clobbered.

    -- Providers (openai-compatible + OAuth-backed codex).
    ${providerBlock}

    -- MCP servers.
    ${mcpBlock}

    -- Startup defaults: pin model/mode/reasoning so cold start is deterministic.
    -- mode = "yolo" is smelt's always_yolo equivalent (auto-allow all tools;
    -- deny rules still apply). reasoning_effort = "high" mirrors always_thinking.
    smelt.defaults.set({
      model = "${defaultModel}",
      mode = "yolo",
      reasoning_effort = "high",
    })

    -- Always start from the pinned defaults above; ignore the last-used picks
    -- from recent.json (matches maki's deterministic cold-start behavior).
    smelt.remember.set({
      mode = false,
      reasoning_effort = false,
    })

    -- Pricing/cost helper models for background plugins (title/compact/predict/
    -- btw/web_fetch). Each reference must resolve to a registered provider/model.
    ${preferredBlock}

    -- Settings. vim = true matches maki's modal prompt editing; auto_compact
    -- keeps long sessions bounded; restrict_to_workspace downgrades outside-cwd
    -- writes to Ask; redact_secrets off (maki default).
    smelt.settings.vim = true
    smelt.settings.auto_compact = true
    smelt.settings.restrict_to_workspace = true
    smelt.settings.redact_secrets = false

    -- Spawn-session tool: worktree + new Zellij tab running smolvm-agent smelt.
    -- Loaded as a plugin from ~/.config/smelt/plugins/ (auto-sourced after
    -- init.lua; not require-able, since the lua/ dir beside init.lua is not
    -- on smelt's require search path).
  '';

  # AGENTS.md is auto-loaded by smelt from ~/.config/smelt/AGENTS.md (global)
  # and the nearest project-root AGENTS.md. No Lua wiring needed.
  agentsMd = ''
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
in
{
  options.dotfiles.smelt = {
    cloudflareWorkersAi = {
      enable = lib.mkEnableOption "Cloudflare Workers AI as an extra smelt provider" // {
        description = ''
          Install Cloudflare Workers AI as an extra selectable smelt provider
          (GLM 5.2 strong / gpt-oss-120b medium / GLM 4.7 Flash weak). This
          never changes the generated default model. Requires
          CLOUDFLARE_WORKERS_AI_API_TOKEN in the environment and a configured
          account id (dotfiles.smelt.cloudflareWorkersAi.accountId).
        '';
      };
      accountId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Cloudflare account id baked into the Workers AI api_base. smelt's
          provider config is static (no env-var expansion in api_base, and
          provider.middleware only rewrites responses), so unlike maki the
          account id must be a literal here rather than resolved at runtime.
        '';
      };
    };
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        MCP server definitions written to ~/.config/smelt/init.lua via
        smelt.mcp.register. Each attribute set becomes a local stdio MCP
        server (command array + optional env/description/timeout/enabled).
      '';
    };
  };

  config = {
    # Seed the basic-memory MCP server (also configured for maki/omp).
    dotfiles.smelt.mcpServers = {
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
      ".config/smelt/init.lua" = {
        force = true;
        text = initLua;
      };
      ".config/smelt/AGENTS.md" = {
        force = true;
        text = agentsMd;
      };
      ".config/smelt/plugins/spawn_session.lua" = {
        force = true;
        source = ./lua/spawn_session.lua;
      };
    };
  };
}
