{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) neuralwatt smortress;

  allowedModels = lib.concatMapStringsSep ", " (spec: builtins.toJSON spec) (
    lib.concatMap (p: map (m: "${p.providerId}/${m.id}") p.makiModels) [
      neuralwatt
      smortress
    ]
  );

  # always_yolo skips permission prompts (deny rules still apply);
  # always_thinking forces the max reasoning level. bash is off by default in
  # maki, so enable it for the coding-agent toolset.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    maki.setup({
      always_yolo = true,
      always_thinking = "max",
      -- Only the declared neuralwatt models (+ smortress qwen as backup);
      -- exclude every other provider, including the built-in deepseek that
      -- appears when the DEEPSEEK_API_KEY env var is present, and the rest of
      -- neuralwatt's remote catalog. allowed_models wins for selectors,
      -- CLI/API model changes, delegation, and `maki models`.
      provider = {
        default_model = "neuralwatt/deepseek-v4.1-flash",
        allowed_models = { ${allowedModels} },
      },
      -- Search runs on smortress over the tailnet. maki.net refuses private
      -- addresses unless listed, and keeps plain http:// for a listed host.
      -- Port-scoped so the allowlist cannot reach anything else on the host.
      net = {
        allowed_private_hosts = { "smortress:${toString config.dotfiles.searchPort}" },
      },
      plugins = {
        bash = { enabled = true },
        -- The bundled websearch only speaks Exa/You.com; the owned plugin
        -- below finds results on the self-hosted SearXNG instead.
        websearch = { enabled = false },
        -- Bundled project-scoped memory: the `memory` tool, tag-based
        -- retrieval, plain markdown files under the maki state dir.
        memory = { enabled = true },
      },
    })

    require("spawn_session")
    require("resume_session")
    require("websearch_owned")
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
    net = true
  '';

  # Custom providers for maki's providers.toml. Model catalogs and pricing
  # live in providers.nix and are projected into maki's shape via each
  # provider's makiModels attribute. displayName is maki-specific.
  #
  # Not Lua provider plugins: a plugin's base_url must be https or loopback,
  # and smortress serves plain http over the tailnet.
  providersToml = (pkgs.formats.toml { }).generate "maki-providers.toml" {
    ${smortress.providerId} = {
      display_name = "Qwen3.8 uncensored (smortress)";
      protocol = "openai";
      # Fail closed: the maki fish function points SMORTRESS_BASE_URL at the
      # real host only once it resolves into the tailnet, so a disconnected
      # tailnet never sends prompts to whatever local DNS calls `smortress`.
      base_url = "http://127.0.0.1:9/v1";
      # llama.cpp needs no key, but a custom provider refuses to start without one.
      api_key = "none";
      models = smortress.makiModels;
    };
    ${neuralwatt.providerId} = {
      display_name = "Neuralwatt";
      protocol = "openai";
      base_url = neuralwatt.baseUrl;
      api_key_env = neuralwatt.keyEnv;
      models = neuralwatt.makiModels;
    };
  };

  smortressHost = builtins.head (lib.splitString ":" (lib.removePrefix "http://" smortress.baseUrl));
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
      ".config/maki/lua/websearch_owned.lua" = {
        force = true;
        text = builtins.replaceStrings [ "@SEARCH_PORT@" ] [ (toString config.dotfiles.searchPort) ] (
          builtins.readFile ./lua/websearch_owned.lua
        );
      };

      ".config/television/cable/maki-sessions.toml".source = makiSessionCable;
    }
    // {
      ".config/maki/providers.toml" = {
        force = true;
        source = providersToml;
      };
    };
    home.packages = [
      pkgs.rtk
      makiSessionSearchBin
    ];

    programs.fish = {
      functions.maki = {
        description = "maki with per-launch provider endpoints";
        wraps = "maki";
        body = ''
          if ${inTailnet} ${smortressHost}
              set -lx SMORTRESS_BASE_URL ${smortress.baseUrl}
          end
          command maki $argv
        '';
      };
      functions.__maki_session_resume = {
        body = ''
          set -l session_id $argv[1]
          set -l cwd (${makiSessionSearch} cwd "$session_id")
          if not test -d "$cwd"
            printf 'maki session directory no longer exists: %s\n' "$cwd" >&2
            return 1
          end
          cd "$cwd"
          maki --session "$session_id"
        '';
      };
      shellAbbrs.ms = "tv maki-sessions | read -l s; and __maki_session_resume $s";
    };
  };
}
