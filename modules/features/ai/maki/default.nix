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
      -- Follow the terminal's ANSI palette, so the one-time theme preview
      -- recolors maki live and normal sessions inherit the Stylix scheme.
      ui = {
        theme = "system";
      },
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
        -- The Graphiti MCP server below is the only memory.
        memory = { enabled = false },
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

  # Private chat profile. Init disables every tool that can write, run, or
  # reach memory, leaving read-only tools plus the owned TinyFish search.
  # instructions.files = { } drops AGENTS.md and the rest of the project text
  # that loads at any trust level.
  privateInitLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    -- Private chat profile: local qwen only, no memory, no MCP, no project
    -- config, and no tool that writes, runs, or delegates.
    maki.setup({
      always_yolo = true,
      instructions = { files = { } },
      -- A future cwd with a .maki config cannot be trusted interactively here.
      trust = { prompt = false },
      provider = {
        default_model = "${privateModel}",
        allowed_models = { "${privateModel}" },
      },
      plugins = {
        bash = { enabled = false },
        code_execution = { enabled = false },
        edit = { enabled = false },
        write = { enabled = false },
        skill = { enabled = false },
        task = { enabled = false },
        memory = { enabled = false },
        sessions = { enabled = false },
        batch = { enabled = false },
        question = { enabled = false },
        todo_write = { enabled = false },
        -- Fetching arbitrary URLs would let a prompt-injected page exfiltrate
        -- anything the read-only tools can reach.
        webfetch = { enabled = false },
        -- The bundled websearch only speaks Exa/You.com; the owned plugin
        -- below uses the TinyFish Search API instead.
        websearch = { enabled = false },
      },
    })

    require("websearch_owned")
  '';

  # websearch_owned reads TINYFISH_API_KEY from the environment; nothing else
  # in this profile gets a grant.
  privatePluginToml = ''
    [permissions]
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
  providerEntry =
    p:
    lib.nameValuePair p.providerId (
      providerEntries.${p.providerId}
      // {
        protocol = "openai";
        models = p.makiModels;
      }
    );
  mkProvidersToml =
    name: ps: (pkgs.formats.toml { }).generate name (lib.listToAttrs (map providerEntry ps));

  providersToml = mkProvidersToml "maki-providers.toml" providers;

  # The private profile ships the local qwen only, so no remote key or remote
  # model is even visible to a session that runs there.
  privateModel = "${smortress.providerId}/${(lib.head smortress.makiModels).id}";
  privateProvidersToml = mkProvidersToml "maki-private-providers.toml" [ smortress ];

  # A stdio shim rather than a URL entry: maki's HTTP client cannot send the
  # group and cwd headers. The group is fixed at maki start (`/cd` does not
  # restart stdio children). 90s stays above the wrapper's 60s tool deadline and under
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
  # A separate XDG_CONFIG_HOME hides the shared mcp.toml (Graphiti memory) and
  # providers.toml (remote keys). State, data, cache, and logs go to tmpfs and
  # are removed on exit, so no transcript reaches disk. The cwd is an empty
  # tmpfs directory, so no project config, commands, or instruction files load.
  makiPrivate = pkgs.writeShellScriptBin "maki-private" ''
    set -eu
    umask 077
    for arg in "$@"; do
      case "$arg" in
        --no-plugins | --trust)
          printf 'maki-private: %s would bypass the private profile\n' "$arg" >&2
          exit 2
          ;;
      esac
    done
    if [ -z "''${HOME:-}" ]; then
      printf 'maki-private: HOME is not set\n' >&2
      exit 1
    fi
    # Startup would otherwise move ~/.maki into the tmpfs config and run its
    # init.lua, so refuse rather than silently consume the legacy data.
    if [ -e "$HOME/.maki" ]; then
      printf 'maki-private: refusing to start: legacy ~/.maki exists and maki would migrate it\n' >&2
      exit 1
    fi
    # The search plugin needs the key; fish exports it, but a non-fish launcher
    # may not, and the host secret is available in the agent VM.
    if [ -z "''${TINYFISH_API_KEY:-}" ] && [ -r /run/secrets/tinyfish-api-key ]; then
      TINYFISH_API_KEY=$(cat /run/secrets/tinyfish-api-key)
      export TINYFISH_API_KEY
    fi
    runtime="''${XDG_RUNTIME_DIR:-/dev/shm}"
    [ -d "$runtime" ] || runtime=/dev/shm
    root=$(mktemp -d "$runtime/maki-private.XXXXXX")
    cleanup() { [ -d "$root" ] && rm -rf -- "$root"; }
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP
    mkdir -p "$root/state" "$root/data" "$root/cache" "$root/cwd" "$root/logs"
    cd "$root/cwd"
    XDG_CONFIG_HOME="$HOME/.config/maki-private" \
    XDG_STATE_HOME="$root/state" \
    XDG_DATA_HOME="$root/data" \
    XDG_CACHE_HOME="$root/cache" \
    OTEL_SDK_DISABLED=true \
    MAKI_ENABLE_TELEMETRY=false \
    maki -m ${privateModel} --no-commands "$@"
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

      ".config/maki-private/maki/init.lua" = {
        force = true;
        text = privateInitLua;
      };
      ".config/maki-private/maki/plugin.toml" = {
        force = true;
        text = privatePluginToml;
      };
      ".config/maki-private/maki/providers.toml" = {
        force = true;
        source = privateProvidersToml;
      };
      ".config/maki-private/maki/lua/websearch_owned.lua" = {
        force = true;
        source = ./lua/websearch_owned.lua;
      };
    };

    home.packages = [
      pkgs.rtk
      makiPrivate
      makiSessionSearchBin
      makiSessionResume
      memoryPackage
    ];

    # Agent sessions live in the guest's XDG dirs, so resuming one goes through the VM too.
    user.shellAbbrs.ms = "agent-sandbox pick maki-sessions maki-session-resume";
    # Plain `maki` stays the unsandboxed binary on the host.
    user.shellAbbrs.a = "agent-sandbox maki";
    # Local qwen chat: no memory, no MCP, no tools that write or run, RAM-only transcripts.
    user.shellAbbrs.mp = "maki-private";
  };
}
