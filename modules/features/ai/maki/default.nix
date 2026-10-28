{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (aiProviders) neuralwatt smortress;

  # Work uses the built-in OpenAI provider with a keychain API key, with no
  # personal providers and no search plugin.
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
        privateHosts = [ ];
        searchPlugin = true;
        memoryMcp = true;
      };
      work = {
        providers = [ ];
        allowedModels = [ "openai/*" ];
        defaultModel = "openai/gpt-6.1-sol";
        privateHosts = [ ];
        searchPlugin = false;
        wrapperEnv = workEnv;
        memoryMcp = false;
      };
    }
    .${config.user.aiProfile};

  isServer = builtins.elem "server" config.machine.profiles;
  # Maki's bwrap boundary is Linux-only; the work Mac keeps its own `m` (claude).
  useSandbox = pkgs.stdenv.hostPlatform.isLinux && config.user.aiProfile == "personal";
  homeDirectory = config.home.homeDirectory;

  luaStrings = lib.concatMapStringsSep ", " builtins.toJSON;

  # The wrapper, shim, and `memory` CLI are one derivation; personal homes get
  # all three, work homes get none.
  memoryPackage = import ../memory/package.nix { inherit pkgs; };

  # ports.nix stays the source for the loopback wrapper URL; the shim keeps a
  # matching default so it also works standalone.
  ports = import ../../../ports.nix;

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
      -- and the rest of neuralwatt's remote catalog. Work: OpenAI only.
      -- allowed_models wins for selectors, CLI/API model changes,
      -- delegation, and `maki models`.
      provider = {
        default_model = "${profile.defaultModel}",
        allowed_models = { ${luaStrings profile.allowedModels} },
      },
      -- Personal search uses the Brave Search API over https; no private host
      -- allowlist is needed. The smortress provider uses its own client.
      net = {
        allowed_private_hosts = { ${luaStrings profile.privateHosts} },
      },
      plugins = {
        bash = { enabled = true },
        -- The bundled websearch only speaks Exa/You.com; on personal hosts
        -- the owned plugin below uses the Brave Search API instead, and work
        -- has no search.
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
  # websearch_owned reach the Brave Search API.
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
  # which the loopback URL below satisfies.
  providerEntries = {
    ${smortress.providerId} = {
      display_name = "Qwen3.8 uncensored (smortress)";
      # Loopback: a disconnected tunnel refuses to connect rather than sending
      # prompts to whatever a look-alike host resolves to.
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
      ) profile.providers
    )
  );

  # Work: the OpenAI API key lives in the login keychain and reaches maki
  # alone. A global OPENAI_API_KEY would make the codex CLI bill the key; maki
  # strips built-in provider keys from its bash and MCP children. Maki prefers
  # stored OAuth tokens over the key, so run `maki auth logout openai` once.
  # Any inherited endpoint override is dropped so prompts only go to OpenAI.
  # Store the key with:
  #   security add-generic-password -U -a "$USER" -s ${keychainService} -w
  keychainService = "maki-openai-api-key";
  workEnv = ''
    unset OPENAI_API_KEY OPENAI_BASE_URL
    if key=$(/usr/bin/security find-generic-password -s ${keychainService} -w 2>/dev/null); then
      export OPENAI_API_KEY="$key"
    else
      echo "maki: no OpenAI key in keychain item '${keychainService}' (see modules/features/ai/maki/default.nix)" >&2
    fi
  '';

  # Runtime boundary for Maki. The same-UID bwrap is a path/privilege
  # boundary, not a kernel boundary (see #250's Agents/Maki section). It
  # rebuilds a small root with only what Maki needs: the worktree, its own
  # config/cache/state, the Nix store, the two PATs, and (on laptops) the
  # signing agent socket. Everything else is absent, not merely masked.
  ghShim = pkgs.writeShellScriptBin "gh" ''
    exec gh-pat "$@"
  '';

  sandboxPath = lib.concatStringsSep ":" [
    "${ghShim}/bin"
    "${pkgs.bash}/bin"
    (lib.makeBinPath [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.git
      pkgs.openssh
      pkgs.ripgrep
      pkgs.jq
    ])
    "${homeDirectory}/.nix-profile/bin"
    "${homeDirectory}/.local/bin"
  ];

  # Reuse the host git identity and work/personal includeIfs, then force
  # HTTPS+PAT for the sandbox (there is no ~/.ssh). On smortress Maki signs
  # with the per-host software key generated by the activation below.
  sandboxGitConfig = ''
    [include]
        path = ${homeDirectory}/.config/git/config

    [url "https://github.com/"]
        insteadOf = git@github.com:
        insteadOf = ssh://git@github.com/

    [credential]
        helper = !github-credential-helper
        useHttpPath = true

    ${lib.optionalString isServer ''
      [user]
          signingkey = ${homeDirectory}/.config/maki/signing_ed25519.pub
    ''}
  '';

  agentSandbox =
    if useSandbox then
      pkgs.writeShellApplication {
        name = "agent-sandbox";
        runtimeInputs = [
          pkgs.bubblewrap
          pkgs.coreutils
          pkgs.git
        ];
        text = ''
          if [ "$#" -lt 1 ]; then
            echo "usage: agent-sandbox <command> [args...]" >&2
            exit 2
          fi

          home=$HOME

          if root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
            worktree=$root
          else
            worktree=$PWD
          fi
          case "$worktree" in
            "$home"|"/")
              echo "agent-sandbox: run from a repo or project directory, not $worktree" >&2
              exit 1
              ;;
          esac
          [ -d "$worktree" ] || {
            echo "agent-sandbox: worktree does not exist: $worktree" >&2
            exit 1
          }

          for path in "$home/.local/bin/maki" "$home/.config/maki" "$home/.nix-profile"; do
            [ -e "$path" ] || {
              echo "agent-sandbox: missing $path" >&2
              exit 1
            }
          done

          mkdir -p \
            "$home/.cache/maki" \
            "$home/.cache/maki/gh" \
            "$home/.local/share/maki" \
            "$home/.local/state/maki"

          args=(
            --unshare-pid
            --unshare-user
            --new-session
            --die-with-parent
            --cap-drop ALL
            --proc /proc
            --dev /dev
            --tmpfs /tmp
            --tmpfs /run
            --dir /run/secrets
            --ro-bind /nix/store /nix/store
            --ro-bind /etc /etc
            --ro-bind "$home/.nix-profile" "$home/.nix-profile"
            --ro-bind "$home/.config/maki" "$home/.config/maki"
            --ro-bind-try "$home/.config/git" "$home/.config/git"
            --ro-bind "$home/.local/bin/maki" "$home/.local/bin/maki"
            --ro-bind-try "$home/.gitignore" "$home/.gitignore"
            --bind "$home/.cache/maki" "$home/.cache/maki"
            --bind "$home/.local/share/maki" "$home/.local/share/maki"
            --bind "$home/.local/state/maki" "$home/.local/state/maki"
            --bind-try "$home/.maki" "$home/.maki"
            --bind "$worktree" "$worktree"
            --ro-bind-try /run/secrets/github-personal-pat /run/secrets/github-personal-pat
            --ro-bind-try /run/secrets/github-work-pat /run/secrets/github-work-pat
            --chdir "$worktree"
            --setenv HOME "$home"
            --setenv PATH "${sandboxPath}"
            --setenv TMPDIR /tmp
            --setenv XDG_CONFIG_HOME "$home/.config"
            --setenv XDG_CACHE_HOME "$home/.cache"
            --setenv XDG_DATA_HOME "$home/.local/share"
            --setenv XDG_STATE_HOME "$home/.local/state"
            --setenv XDG_RUNTIME_DIR "/run/user/$(id -u)"
            --setenv GIT_CONFIG_GLOBAL "$home/.config/maki/sandbox-gitconfig"
            --setenv GIT_CONFIG_SYSTEM /dev/null
            --setenv GH_CONFIG_DIR "$home/.cache/maki/gh"
            --setenv MAKI_SANDBOX 1
          )

          common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
          if [ -n "$common" ] && [ "$common" != "$worktree/.git" ] && [ -d "$common" ]; then
            args+=(--bind "$common" "$common")
          fi

          ${lib.optionalString (!isServer) ''
            runtime="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
            args+=(
              --dir /run/user
              --dir "/run/user/$(id -u)"
              --ro-bind-try "$runtime/fido2-sign-agent" "/run/user/$(id -u)/fido2-sign-agent"
              --setenv SSH_AUTH_SOCK "/run/user/$(id -u)/fido2-sign-agent"
            )
          ''}
          ${lib.optionalString isServer ''
            args+=(--unsetenv SSH_AUTH_SOCK)
          ''}

          # spawn_session/resume_session need the outer zellij socket. Keep it
          # out of /run/user so that directory contains only the signing socket.
          zellij_socket_dir="''${ZELLIJ_SOCKET_DIR:-}"
          if [ -n "$zellij_socket_dir" ] && [ -d "$zellij_socket_dir" ]; then
            args+=(
              --bind "$zellij_socket_dir" /tmp/zellij
              --setenv ZELLIJ_SOCKET_DIR /tmp/zellij
            )
          fi

          exec bwrap "''${args[@]}" "$@"
        '';
      }
    else
      null;

  mWrapper =
    if useSandbox then
      pkgs.writeShellScriptBin "m" ''
        exec ${agentSandbox}/bin/agent-sandbox "$HOME/.local/bin/maki" "$@"
      ''
    else
      null;

  # Every launch must go through this, including zellij tabs from
  # spawn_session/resume_session, which exec `maki` without a shell. The
  # binary itself is installed manually into ~/.local/bin, so the wrapper is
  # put on the session PATH explicitly ahead of it (see home.sessionPath
  # below) rather than trusting each OS's profile ordering.
  makiWrapper = pkgs.writeShellScriptBin "maki" ''
    ${lib.optionalString (profile ? wrapperEnv) profile.wrapperEnv}
    ${lib.optionalString useSandbox ''
      if [ "''${MAKI_SANDBOX:-0}" != 1 ]; then
        exec ${agentSandbox}/bin/agent-sandbox "$HOME/.local/bin/maki" "$@"
      fi
    ''}
    exec "$HOME/.local/bin/maki" "$@"
  '';

  # Maki's memory MCP. The stdio shim inherits Maki's cwd, derives the project
  # group there, refuses work repos, and forwards to the loopback wrapper with
  # the group and cwd as headers. Maki's HTTP client sends neither, so a URL
  # entry cannot do this. Maki reads this file once at startup: restart it after
  # a change, and after `cd`-ing to a different repo (`/cd` does not restart
  # stdio children, so the group is fixed when Maki starts). The wrapper is
  # loopback on every personal machine: on smortress it is the service itself,
  # elsewhere cloudflared-memory forwards the same port and adds the Cloudflare
  # Access service token. The name must not collide with a built-in tool
  # (`memory` is one), so it stays `graphiti`. 90s stays above the wrapper's 60s
  # tool deadline and under Cloudflare's ~100s origin timeout.
  mcpEnvironment = {
    MEMORY_MCP_URL = "http://127.0.0.1:${toString ports.memoryMcp}/mcp";
    MEMORY_WORK_EMAIL = config.user.work.email;
    MEMORY_WORK_OWNER_GLOB = config.user.work.githubOwnerGlob;
    MEMORY_WORK_FLOW = config.user.work.flow;
    MEMORY_WORK_SSH_MARKER = baseNameOf config.user.work.sshConfig;
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

  # maki-session-resume <id>: reopens a session in the directory it ran in.
  # A script rather than a shell function so every shell shares it; maki
  # (the PATH wrapper) is found the same way an interactive call would.
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
        source = ./lua/websearch_owned.lua;
      };
    }
    // lib.optionalAttrs (profile.providers != [ ]) {
      ".config/maki/providers.toml" = {
        force = true;
        source = providersToml;
      };
    }
    // lib.optionalAttrs profile.memoryMcp {
      ".config/maki/mcp.toml" = {
        force = true;
        text = mcpToml;
      };
    }
    // lib.optionalAttrs useSandbox {
      ".config/maki/sandbox-gitconfig" = {
        force = true;
        text = sandboxGitConfig;
      };
    };
    # Maki's signing identity on smortress is a host-local software key: no
    # YubiKey is present there and the forwarded agent is hidden from the
    # sandbox. Generate it once, outside the sandbox, and print the public
    # half so it can be added to allowed_signers (T1) and GitHub.
    home.activation.makiSigningKey = lib.mkIf (useSandbox && isServer) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        key="$HOME/.config/maki/signing_ed25519"
        if [ ! -f "$key" ]; then
          umask 077
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$key")"
          run ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "maki@smortress" -f "$key"
        fi
        run ${pkgs.coreutils}/bin/chmod 600 "$key"
        echo "maki signing key: $(${pkgs.coreutils}/bin/cat "$key.pub")" >&2
      ''
    );
    home.sessionPath = lib.mkBefore [ "${makiWrapper}/bin" ];
    # Tool-owned rc files (the work host's ~/.zshrc chain) prepend
    # ~/.local/bin after the session PATH, which would shadow the wrapper with
    # the raw binary; re-assert it after ~/.zshrc is sourced (order 600).
    programs.zsh.initContent = lib.mkOrder 700 ''
      path=(${makiWrapper}/bin ''${path:#${makiWrapper}/bin})
    '';
    # The ingest CLI derives repo paths and gh targets from this; the option is
    # the source of truth, so the Python default never drifts from the profile.
    home.sessionVariables = lib.optionalAttrs profile.memoryMcp {
      MEMORY_PERSONAL_OWNER = config.user.githubUser;
    };

    home.packages = [
      makiWrapper
      pkgs.rtk
      makiSessionSearchBin
      makiSessionResume
    ]
    ++ lib.optionals profile.memoryMcp [ memoryPackage ]
    ++ lib.optionals useSandbox [
      agentSandbox
      mWrapper
    ];

    user.shellAbbrs.ms = "pick maki-sessions maki-session-resume";
    # `m` is the sandboxed entry point on personal Linux hosts; the work Mac
    # overrides this to `claude` in its host meta.
    user.shellAbbrs.m = lib.mkIf useSandbox "m";
  };
}
