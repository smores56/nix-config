{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) neuralwatt smortress;

  # providers.toml entries and the allowed_models list both come from here.
  providers = [
    neuralwatt
    smortress
  ];
  allowedModels = lib.concatMap (p: map (m: "${p.providerId}/${m.id}") p.makiModels) providers;

  luaStrings = lib.concatMapStringsSep ", " builtins.toJSON;

  # The wrapper, shim, and `memory` CLI are one derivation.
  memoryPackage = import ../memory/package.nix { inherit pkgs; };

  # The shim keeps a matching default so it also works standalone.
  ports = import ../../../ports.nix;

  # bash is off by default in maki; the coding-agent toolset needs it.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    maki.setup({
      always_yolo = true,
      always_thinking = "max",
      -- Only the declared neuralwatt models (+ smortress qwen as backup),
      -- excluding every other provider, including the built-in deepseek that
      -- appears when the DEEPSEEK_API_KEY env var is present, and the rest of
      -- neuralwatt's remote catalog.
      -- allowed_models wins for selectors, CLI/API model changes,
      -- delegation, and `maki models`.
      provider = {
        default_model = "neuralwatt/deepseek-v4.1-flash",
        allowed_models = { ${luaStrings allowedModels} },
      },
      -- Search uses the TinyFish Search API over https; no private host
      -- allowlist is needed. The smortress provider uses its own client.
      net = {
        allowed_private_hosts = { },
      },
      plugins = {
        bash = { enabled = true },
        -- The bundled websearch only speaks Exa/You.com; the owned plugin
        -- below uses the TinyFish Search API instead.
        websearch = { enabled = false },
        -- Bundled project-scoped memory: the `memory` tool, tag-based
        -- retrieval, plain markdown files under the maki state dir.
        memory = { enabled = true },
      },
    })

    require("websearch_owned")
  '';

  # `run` is needed by plugin jobstart calls; `net` lets websearch_owned reach TinyFish.
  pluginToml = ''
    [permissions]
    fs_read = true
    fs_write = true
    run = true
    env = true
    net = true
  '';

  # Catalogs and pricing live in providers.nix; display names and auth wiring here.
  providerEntries = {
    ${smortress.providerId} = {
      display_name = "Qwen3.8 uncensored (smortress)";
      # Loopback: a down tunnel refuses rather than leaking prompts to a look-alike host.
      base_url = smortress.baseUrl;
      # llama.cpp needs no key, but a custom provider refuses to start without one.
      api_key = "none";
    };
    ${neuralwatt.providerId} = {
      display_name = "Neuralwatt";
      base_url = neuralwatt.baseUrl;
      api_key_env = neuralwatt.keyEnv;
    };
  };
  providersToml = (pkgs.formats.toml { }).generate "maki-providers.toml" (
    lib.listToAttrs (
      map (
        p:
        lib.nameValuePair p.providerId (
          providerEntries.${p.providerId}
          // {
            protocol = "openai";
            models = p.makiModels;
          }
        )
      ) providers
    )
  );

  # A stdio shim rather than a URL entry: maki's HTTP client cannot send the
  # group and cwd headers. The group is fixed at maki start (`/cd` does not
  # restart stdio children). The name `graphiti` avoids the built-in `memory`
  # tool. 90s stays above the wrapper's 60s tool deadline and under
  # Cloudflare's ~100s origin timeout.
  mcpEnvironment = {
    MEMORY_MCP_URL = "http://127.0.0.1:${toString ports.memoryMcp}/mcp";
    # The listener demands the bearer token even on loopback: the tunnel makes
    # remote clients look local. The shim reads the file itself.
    MEMORY_MCP_TOKEN_FILE = "/run/secrets/memory-mcp-token";
    MEMORY_WORK_EMAIL = config.user.work.email;
    MEMORY_WORK_OWNER_GLOB = lib.concatStringsSep "," config.user.work.githubOwners;
    MEMORY_WORK_FLOW = config.user.work.flow;
  };
  mcpEnvironmentToml =
    "{ "
    + lib.concatStringsSep ", " (
      lib.mapAttrsToList (key: value: "${key} = ${builtins.toJSON value}") mcpEnvironment
    )
    + " }";
  mcpToml = ''
    [mcp.graphiti]
    command = ["${memoryPackage}/bin/memory-mcp-shim"]
    timeout = 90000
    environment = ${mcpEnvironmentToml}
  '';

  # Deny wins over always_yolo. A backstop against a compromised model or
  # prompt injection, not a sandbox: obfuscated forms can slip through.
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
      "zsh",
      "fish",
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

  # A script rather than a shell function so every shell shares it.
  makiSessionResume = pkgs.writeShellScriptBin "maki-session-resume" ''
    session_id=''${1:?usage: maki-session-resume <session-id>}
    cwd=$(${makiSessionSearch} cwd "$session_id")
    if [ ! -d "$cwd" ]; then
      printf 'maki session directory no longer exists: %s\n' "$cwd" >&2
      exit 1
    fi
    cd "$cwd" || exit 1
    exec maki --session "$session_id"
  '';
  # On PATH so the maki Lua plugin can jobstart it by name.
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
          ${config.ai.hints}
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
            the machine/user contract
          - Acceptance criteria: behavioral for implementation, evidence for research
          - The coordinator verifies — narrowest relevant validation first,
            broaden only on failed focused checks
        '';
      };

      ".config/television/cable/maki-sessions.toml".source = makiSessionCable;
      ".config/maki/lua/websearch_owned.lua" = {
        force = true;
        source = ./lua/websearch_owned.lua;
      };
      ".config/maki/providers.toml" = {
        force = true;
        source = providersToml;
      };
      ".config/maki/mcp.toml" = {
        force = true;
        text = mcpToml;
      };
    };

    home.packages = [
      pkgs.rtk
      makiSessionSearchBin
      makiSessionResume
      memoryPackage
    ];

    user.shellAbbrs.ms = "pick maki-sessions maki-session-resume";
    # Plain `maki` stays the unsandboxed binary.
    user.shellAbbrs.m = "agent-sandbox maki";
  };
}
