{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) neuralwatt smortress;

  # Everything that differs between AI profiles. Work keeps maki on
  # Anthropic so work code never reaches a personal provider: no personal
  # providers, no smortress SearXNG search, and the API key comes from the
  # keychain instead of the tailnet gate.
  profile =
    {
      personal = {
        # providers.toml entries and the allowed_models list both come from here.
        providers = [
          neuralwatt
          smortress
        ];
        allowedModels = lib.concatMap (
          p: map (m: "${p.providerId}/${m.id}") p.makiModels
        ) profile.providers;
        defaultModel = "neuralwatt/deepseek-v4.1-flash";
        privateHosts = [ "${smortress.host}:${toString config.dotfiles.searchPort}" ];
        searchPlugin = true;
        wrapperEnv = personalEnv;
      };
      work = {
        providers = [ ];
        allowedModels = [ "anthropic/*" ];
        defaultModel = "anthropic/claude-opus-5-5";
        privateHosts = [ ];
        searchPlugin = false;
        wrapperEnv = workEnv;
      };
    }
    .${config.dotfiles.aiProfile};

  luaStrings = lib.concatMapStringsSep ", " builtins.toJSON;

  # always_yolo skips permission prompts (deny rules still apply);
  # always_thinking forces the max reasoning level. bash is off by default in
  # maki, so enable it for the coding-agent toolset.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    maki.setup({
      always_yolo = true,
      always_thinking = "max",
      -- Personal: only the declared neuralwatt models (+ smortress qwen as
      -- backup), excluding every other provider, including the built-in
      -- deepseek that appears when the DEEPSEEK_API_KEY env var is present,
      -- and the rest of neuralwatt's remote catalog. Work: Anthropic only.
      -- allowed_models wins for selectors, CLI/API model changes,
      -- delegation, and `maki models`.
      provider = {
        default_model = "${profile.defaultModel}",
        allowed_models = { ${luaStrings profile.allowedModels} },
      },
      -- Personal search runs on smortress over the tailnet. maki.net refuses
      -- private addresses unless listed, and keeps plain http:// for a listed
      -- host. Port-scoped so the allowlist cannot reach anything else on the
      -- host.
      net = {
        allowed_private_hosts = { ${luaStrings profile.privateHosts} },
      },
      plugins = {
        bash = { enabled = true },
        -- The bundled websearch only speaks Exa/You.com; on personal hosts
        -- the owned plugin below finds results on the self-hosted SearXNG
        -- instead, and work has no search.
        websearch = { enabled = false },
        -- Bundled project-scoped memory: the `memory` tool, tag-based
        -- retrieval, plain markdown files under the maki state dir.
        memory = { enabled = true },
      },
    })

    require("spawn_session")
    require("resume_session")
    ${lib.optionalString profile.searchPlugin ''require("websearch_owned")''}
  '';

  # Permissions manifest for the Lua plugins under ./lua. `run` is needed by
  # spawn_session's maki.fn.jobstart (process spawn); `net` lets
  # websearch_owned reach the self-hosted SearXNG.
  pluginToml = ''
    [permissions]
    fs_read = true
    fs_write = true
    run = true
    env = true
    net = ${lib.boolToString profile.searchPlugin}
  '';

  # Custom providers for maki's providers.toml. Model catalogs and pricing
  # live in providers.nix and are projected into maki's shape via each
  # provider's makiModels attribute; display names and auth wiring live here.
  #
  # Not Lua provider plugins: a plugin's base_url must be https or loopback,
  # and smortress serves plain http over the tailnet.
  providerEntries = {
    ${smortress.providerId} = {
      display_name = "Qwen3.8 uncensored (smortress)";
      # Fail closed: the maki wrapper points SMORTRESS_BASE_URL at the real
      # host only once it resolves into the tailnet, so a disconnected
      # tailnet never sends prompts to whatever local DNS calls `smortress`.
      base_url = "http://127.0.0.1:9/v1";
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
      ) profile.providers
    )
  );

  inTailnet = pkgs.writers.writePython3 "maki-in-tailnet" { } ''
    import ipaddress
    import socket
    import sys

    try:
        addr = ipaddress.ip_address(socket.gethostbyname(sys.argv[1]))
    except OSError:
        sys.exit(1)
    sys.exit(0 if addr in ipaddress.ip_network("100.64.0.0/10") else 1)
  '';

  # Personal: smortress is reached only once it resolves into the tailnet;
  # an inherited SMORTRESS_BASE_URL (e.g. a nested maki from the bash tool)
  # is dropped so the gate decides afresh.
  personalEnv = ''
    if ${inTailnet} ${smortress.host}; then
      export SMORTRESS_BASE_URL=${smortress.baseUrl}
    else
      unset SMORTRESS_BASE_URL
    fi
  '';
  # Work: the Anthropic API key lives in the login keychain and reaches maki
  # alone. A global ANTHROPIC_API_KEY would make Claude Code bill the key
  # instead of the subscription seat; maki strips built-in provider keys from
  # its bash and MCP children, so a `claude` it runs never sees the key. Any
  # inherited endpoint override (a Claude Code proxy or Bedrock setting, a
  # repo's direnv) is dropped so the key and prompts only go to Anthropic.
  # Store the key with:
  #   security add-generic-password -U -a "$USER" -s ${keychainService} -w
  keychainService = "maki-anthropic-api-key";
  workEnv = ''
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
      ANTHROPIC_BEDROCK_BASE_URL CLAUDE_CODE_USE_BEDROCK
    if key=$(/usr/bin/security find-generic-password -s ${keychainService} -w 2>/dev/null); then
      export ANTHROPIC_API_KEY="$key"
    else
      echo "maki: no Anthropic key in keychain item '${keychainService}' (see modules/features/ai/maki/default.nix)" >&2
    fi
  '';

  # Every launch must go through this, including zellij tabs from
  # spawn_session/resume_session, which exec `maki` without a shell. The
  # binary itself is installed manually into ~/.local/bin, so the wrapper is
  # put on the session PATH explicitly ahead of it (see home.sessionPath
  # below) rather than trusting each OS's profile ordering.
  makiWrapper = pkgs.writeShellScriptBin "maki" ''
    ${profile.wrapperEnv}
    exec "$HOME/.local/bin/maki" "$@"
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
      "zsh",
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
    // lib.optionalAttrs profile.searchPlugin {
      ".config/maki/lua/websearch_owned.lua" = {
        force = true;
        text = builtins.replaceStrings [ "@SEARCH_PORT@" ] [ (toString config.dotfiles.searchPort) ] (
          builtins.readFile ./lua/websearch_owned.lua
        );
      };
    }
    // lib.optionalAttrs (profile.providers != [ ]) {
      ".config/maki/providers.toml" = {
        force = true;
        source = providersToml;
      };
    };
    home.sessionPath = lib.mkBefore [ "${makiWrapper}/bin" ];

    home.packages = [
      makiWrapper
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
