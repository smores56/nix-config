# The Linux agent VM (smores56/sdlc#386): agents run in a microvm.nix NixOS guest, so nothing they
# do can reach the host's sudo, polkit, YubiKey or session sockets. `agent-sandbox maki`
# (modules/features/agent-vm) opens an SSH session into it.
#
# The guest sees $HOME at the same path through one virtiofs share of a host-assembled view
# (modules/lib/agent_view.py): only `allow` (read-only) and `allowRw` (read-write); anything else
# has no path in the guest. virtiofsd squashes every guest uid to the human's, so guest root
# cannot plant root-owned or setuid-root files.
{
  config,
  lib,
  pkgs,
  inputs,
  aiProviders,
  ...
}:
let
  cfg = config.agentVm;
  ports = import ../ports.nix;
  user = config.machine.username;
  home = "/home/${user}";
  uid = 1000;
  gid = 100;

  # Each capability is one guest-visible port and one host broker. `brokerPort` defaults to the
  # guest port; a capability fronting an existing host service names a distinct one.
  caps = lib.mapAttrs (
    _: c: c // { brokerPort = if c.brokerPort == 0 then c.guestPort else c.brokerPort; }
  ) cfg.capabilities;

  brokerPackage = pkgs.callPackage ../lib/agent-broker/package.nix { };

  # Shared by the boot-time build and the live reconcile, so the two cannot diverge.
  plannerArgs = lib.escapeShellArgs (
    lib.concatMap (d: [
      "--allow"
      d
    ]) cfg.allow
    ++ lib.concatMap (r: [
      "--allow-rw"
      r
    ]) cfg.allowRw
  );

  calibredbWrapper = pkgs.writeShellScriptBin "calibredb" ''
    for a in "$@"; do
      case "$a" in
        --with-library | --with-library=* | -w | -w=*) exec ${pkgs.calibre}/bin/calibredb "$@";;
      esac
    done
    if [ -n "''${CALIBRE_LIBRARY_URL:-}" ]; then
      exec ${pkgs.calibre}/bin/calibredb --with-library "$CALIBRE_LIBRARY_URL" "$@"
    fi
    exec ${pkgs.calibre}/bin/calibredb "$@"
  '';
  # calibre's other binaries plus the broker-aware calibredb; one package so the profile has no
  # duplicate bin/calibredb.
  guestCalibre = pkgs.runCommandLocal "calibre-agent" { } ''
    mkdir -p $out/bin
    for b in ${pkgs.calibre}/bin/*; do
      n=$(basename "$b")
      if [ "$n" = calibredb ]; then continue; fi
      ln -s "$b" "$out/bin/$n"
    done
    ln -s ${calibredbWrapper}/bin/calibredb "$out/bin/calibredb"
  '';

  # Holds the Access token on the host; the guest only dials the relay.
  cloudflaredAccess = pkgs.writeShellApplication {
    name = "cloudflared-access-host";
    runtimeInputs = [ pkgs.cloudflared ];
    text = ''
      {
        IFS= read -r token_id || true
        IFS= read -r token_secret || true
      } < "$CREDENTIALS_DIRECTORY/cloudflare-access-ssh-token"
      export TUNNEL_SERVICE_TOKEN_ID="$token_id" TUNNEL_SERVICE_TOKEN_SECRET="$token_secret"
      exec cloudflared access "$@"
    '';
  };
  guestSshProxy = pkgs.writeShellScriptBin "agent-vm-ssh-proxy" ''
    exec ${pkgs.socat}/bin/socat - TCP:127.0.0.1:${toString ports.agentSshRelay}
  '';

  # What the guest may know about its capabilities: addresses and dummy values, never secrets.
  capabilityJson = pkgs.writeText "agent-vm-capabilities.json" (
    builtins.toJSON {
      capabilities = lib.mapAttrs (_: c: {
        inherit (c) type guestPort;
        url = "http://127.0.0.1:${toString c.guestPort}";
        inherit (c) env;
      }) caps;
    }
  );
  capabilityEnv = pkgs.writeText "agent-vm-capabilities.env" (
    lib.concatStrings (
      lib.mapAttrsToList (
        _: c: lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") c.env)
      ) caps
    )
  );

  nanobotPackage = pkgs.nanobot;
  lettaPackage = pkgs.letta;
  # One state path: the wrapper, the host view, the unit's sandbox and the backup all read it.
  assistantState = vmLib.assistantState user;
  lettaState = "${home}/.local/state/letta";
  sdlcGuest = import ../lib/sdlc.nix { inherit pkgs; };
  sharedSkillNames = import ../lib/skills.nix ../features/ai/skills;
  # `brain` reads the work-memory instance; the assistant keeps the shared skills only.
  assistantSkills = lib.subtractLists [ "brain" ] sharedSkillNames;

  # The query is one argument list, so search text can never become shell syntax.
  tinyfishSearch = pkgs.writeShellApplication {
    name = "tinyfish-search";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      set -euo pipefail
      if [ $# -eq 0 ]; then
        echo "usage: tinyfish-search <query>" >&2
        exit 2
      fi
      exec curl -sS --max-time 20 -H 'Accept: application/json' \
        --get --data-urlencode "query=$*" "$TINYFISH_BASE_URL"
    '';
  };

  tinyfishSkill = pkgs.writeText "tinyfish-search-SKILL.md" ''
    ---
    name: tinyfish-search
    description: Search the web with the TinyFish Search API for current results.
    metadata: {"nanobot":{"requires":{"bins":["tinyfish-search"]}}}
    ---

    # TinyFish search

    Run the helper with the query as one argument; it URL-encodes the query. The
    host broker adds the API key.

    ```sh
    tinyfish-search "QUERY"
    ```

    Read `.results[]` and use `title`, `url`, and `snippet` in the answer. If the
    call fails or returns no results, fall back to the built-in `web_search`.
  '';

  nanobotConfig = pkgs.writeText "nanobot-config.json" (
    builtins.toJSON {
      providers = {
        custom = {
          apiKey = "none";
          apiBase = "http://127.0.0.1:${toString ports.agentNeuralwatt}/v1";
        };
        smortress = {
          apiKey = null;
          apiBase = aiProviders.smortress.baseUrl;
        };
      };
      modelPresets = {
        neuralwatt = {
          provider = "custom";
          model = aiProviders.neuralwatt.models.deepseekFlash.id;
          maxTokens = aiProviders.neuralwatt.models.deepseekFlash.max_output_tokens;
          contextWindowTokens = aiProviders.neuralwatt.models.deepseekFlash.context_window;
        };
        # The outage fallback. The windows stay small so a prompt does not try to
        # fill the local model's full 200k context on a shared machine.
        local = {
          provider = "smortress";
          model = aiProviders.smortress.models.qwen38.id;
          maxTokens = 8192;
          contextWindowTokens = 32768;
        };
      };
      agents.defaults = {
        modelPreset = "neuralwatt";
        disabled_skills = [
          "summarize"
          "tmux"
          "clawhub"
          "image-generation"
          "memory"
        ];
        dream = {
          enabled = false;
        };
      };
      channels.websocket = {
        enabled = true;
        host = "127.0.0.1";
        port = ports.agent;
        tokenIssueSecret = "\${NANOBOT_WEB_TOKEN}";
        websocketRequiresToken = true;
      };
      transcription = {
        enabled = false;
      };
      tools = {
        restrict_to_workspace = false;
        web = {
          search = {
            provider = "duckduckgo";
            max_results = 5;
          };
          fetch = {
            # Fetch directly from the sandbox rather than through r.jina.ai, which
            # would see every URL the agent reads.
            use_jina_reader = false;
          };
        };
        exec = {
          path_prepend = "/run/current-system/sw/bin:/run/wrappers/bin";
          allowed_env_keys = [
            "GH_TOKEN"
            "TINYFISH_BASE_URL"
            "SDLC_REPO"
            "GH_CONFIG_DIR"
            "GIT_CONFIG_GLOBAL"
          ];
        };
        cli_apps = {
          enable = false;
        };
        image_generation = {
          enabled = false;
        };
        ssrf_whitelist = [
          # The capability brokers and the memory MCP listen on the guest's loopback.
          "127.0.0.1/32"
        ];
        mcp_servers.memory = {
          type = "streamableHttp";
          url = "http://127.0.0.1:${toString ports.memoryMcp}/mcp";
          headers = {
            "X-Memory-Group" = "global";
            "X-Memory-Cwd" = home;
            "X-Memory-Actor" = "nanobot";
            "X-Memory-Machine" = "smortress";
          };
          tool_timeout = 30;
        };
      };
    }
  );

  agentAssistant = pkgs.writeShellApplication {
    name = "agent-assistant";
    runtimeInputs = [
      nanobotPackage
      pkgs.openssl
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gh
      pkgs.git
      pkgs.jq
      pkgs.ripgrep
      pkgs.curl
      pkgs.sqlite
      sdlcGuest
    ];
    text = ''
      set -eu
      state=${lib.escapeShellArg assistantState}
      export HOME="$state/home"
      export XDG_STATE_HOME="$HOME/.local/state"
      export XDG_CACHE_HOME="$HOME/.cache"
      export XDG_DATA_HOME="$HOME/.local/share"
      export GH_CONFIG_DIR="$state/gh"
      export GIT_CONFIG_GLOBAL="${home}/.config/git/config"
      export SDLC_REPO="smores56/sdlc"
      mkdir -p "$HOME/.nanobot/workspace/skills" "$GH_CONFIG_DIR"
      # Sessions and the WebUI token live here; keep other host users out of the tree.
      chmod 700 "$state"
      if [ -r /run/agent-vm/capabilities.env ]; then
        # shellcheck source=/dev/null
        . /run/agent-vm/capabilities.env
      fi
      if [ -r /run/secrets/github-personal-pat ]; then
        GH_TOKEN="$(cat /run/secrets/github-personal-pat)"
        export GH_TOKEN
      fi
      # Nix owns the config while it still says what Nix wrote. Compare normalized
      # JSON, because nanobot re-serializes on a settings save; a missing pristine
      # copy means this state predates the split, so Nix installs and adopts it.
      config="$HOME/.nanobot/config.json"
      pristine="$state/nanobot-config.json"
      nix_owns_config() {
        [ ! -e "$pristine" ] && return 0
        jq -S . "$config" 2>/dev/null | cmp -s - <(jq -S . "$pristine" 2>/dev/null)
      }
      if [ ! -e "$config" ] || nix_owns_config; then
        install -m 600 ${nanobotConfig} "$config"
      fi
      install -m 600 ${nanobotConfig} "$pristine"
      if [ ! -s "$HOME/.nanobot/web-token" ]; then
        (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 32 > "$HOME/.nanobot/web-token")
      fi
      NANOBOT_WEB_TOKEN="$(cat "$HOME/.nanobot/web-token")"
      export NANOBOT_WEB_TOKEN
      install -D -m 644 ${tinyfishSkill} "$HOME/.nanobot/workspace/skills/tinyfish-search/SKILL.md"
      for s in ${lib.escapeShellArgs assistantSkills}; do
        ln -sfn "${home}/.agents/skills/$s" "$HOME/.nanobot/workspace/skills/$s"
      done
      case "''${1:-}" in
        token) cat "$HOME/.nanobot/web-token" ;;
        # The sessions database is on the virtiofs share, and only this guest may open it:
        # a host process bypasses the guest's WAL locks and corrupts the live connection.
        # The host backup calls this through agent-sandbox, then snapshots the copies.
        dump)
          root="$HOME/.nanobot"
          out="$state/backup"
          install -d -m 0700 "$out"
          found=0
          for db in "$root"/sessions/*/sessions.sqlite3 "$root"/sessions/sessions.sqlite3; do
            [ -e "$db" ] || continue
            case "$db" in
              */sessions/sessions.sqlite3) id=legacy ;;
              *) id=''${db%/sessions.sqlite3}; id=''${id##*/} ;;
            esac
            install -d -m 0700 "$out/$id"
            tmp="$out/$id/sessions.sqlite3.tmp"
            sqlite3 "$db" ".backup '$tmp'"
            mv "$tmp" "$out/$id/sessions.sqlite3"
            found=1
          done
          [ "$found" -eq 1 ] || rm -rf "$out"
          ;;
        # The supervised entry point; `webui` is an interactive client that exits
        # when the gateway does, so it must never be the unit's ExecStart.
        gateway) exec ${nanobotPackage}/bin/nanobot gateway --foreground ;;
        serve) exec ${nanobotPackage}/bin/nanobot webui --no-open ;;
        *) exec ${nanobotPackage}/bin/nanobot "$@" ;;
      esac
    '';
  };

  # Letta's provider record, written by Nix so the guest never needs an interactive
  # `/connect`. The broker injects the real key, so the guest-side key is the placeholder
  # Letta itself uses for keyless OpenAI-compatible endpoints.
  lettaProviderAuth = pkgs.writeText "letta-provider-auth.json" (
    builtins.toJSON {
      version = 1;
      providers = {
        lc-openai-compatible = {
          id = "local-provider-lc-openai-compatible";
          name = "lc-openai-compatible";
          provider_type = "openai-compatible";
          provider_category = "byok";
          auth = {
            type = "api";
            key = "not-needed";
          };
          base_url = "http://127.0.0.1:${toString ports.agentNeuralwatt}/v1";
          created_at = "1970-01-01T00:00:00.000Z";
          updated_at = "1970-01-01T00:00:00.000Z";
        };
      };
    }
  );

  # The App Server writes `~/.letta/settings.json` on startup, so HOME has to be writable
  # even though the backend directory is pinned separately. Both live under the one state
  # path the view shares and the backup walks.
  agentLetta = pkgs.writeShellApplication {
    name = "agent-letta";
    runtimeInputs = [
      lettaPackage
      pkgs.coreutils
      pkgs.diffutils
      pkgs.jq
    ];
    text = ''
      set -eu
      state=${lib.escapeShellArg lettaState}
      export HOME="$state/home"
      export XDG_STATE_HOME="$HOME/.local/state"
      export XDG_CACHE_HOME="$HOME/.cache"
      export XDG_DATA_HOME="$HOME/.local/share"
      export LETTA_LOCAL_BACKEND_DIR="$state/backend"
      # The packaged CLI must never try to update itself inside a read-only store.
      export DISABLE_AUTOUPDATER=1
      mkdir -p "$HOME" "$state/backend/providers"
      chmod 700 "$state"
      # Nix owns the provider record while it still says what Nix wrote; Letta rewrites
      # auth.json on `/connect`, so a changed file is the human's and is left alone.
      auth="$state/backend/providers/auth.json"
      pristine="$state/letta-provider-auth.json"
      if [ ! -e "$auth" ] || jq -S . "$auth" 2>/dev/null | cmp -s - <(jq -S . "$pristine" 2>/dev/null); then
        install -m 600 ${lettaProviderAuth} "$auth"
      fi
      install -m 600 ${lettaProviderAuth} "$pristine"
      case "''${1:-}" in
        server)
          shift
          exec ${lettaPackage}/bin/letta server --backend local \
            --listen "ws://127.0.0.1:${toString ports.letta}" "$@"
          ;;
        *) exec ${lettaPackage}/bin/letta "$@" ;;
      esac
    '';
  };

  brokerConfig =
    c:
    pkgs.writeText "agent-broker-${toString c.guestPort}.json" (
      builtins.toJSON {
        listen = "127.0.0.1:${toString c.brokerPort}";
        inherit (c) upstream allow;
        auth = {
          inherit (c.auth) kind header username;
          credential = c.secret;
        };
      }
    );

  brokerService = c: {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      LoadCredential = "${c.secret}:/run/secrets/${c.secret}";
      ExecStart = "${brokerPackage}/bin/agent-broker ${brokerConfig c}";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };

  # A TCP capability owns its listener through the declared command; the token reaches it as a
  # systemd credential, so the command reads $CREDENTIALS_DIRECTORY/<secret>.
  tcpService = c: {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      LoadCredential = "${c.secret}:/run/secrets/${c.secret}";
      ExecStart = "/bin/sh -c ${
        lib.escapeShellArg (lib.replaceStrings [ "%PORT%" ] [ (toString c.brokerPort) ] c.command)
      }";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  brokerServices = lib.mapAttrs' (
    n: c:
    lib.nameValuePair "agent-broker-${n}" (if c.type == "http" then brokerService c else tcpService c)
  ) caps;

  # Stable guest-visible ports. `proxied` reaches host services directly; each capability goes
  # to its broker instead while keeping the same port in the guest.
  relays =
    map (p: {
      port = p;
      target = p;
    }) proxied
    ++ lib.mapAttrsToList (_: c: {
      port = c.guestPort;
      target = c.brokerPort;
    }) caps;

  vmLib = import ../lib/agent-vm.nix { inherit pkgs lib; };
  inherit (vmLib)
    name
    tap
    hostAddr
    guestAddr
    stateDir
    ;
  # Locally administered unicast, fixed so the guest's networkd match never changes.
  guestMac = "02:00:0a:4d:00:02";

  runDir = "/run/agent-vm";
  view = "${runDir}/home";
  secretsDir = "${runDir}/secrets";
  authorizedKeys = "agent-vm-authorized-keys";
  # Shared maki state (the launcher leaves XDG_STATE_HOME at its default). The guest cannot
  # create them under the read-only view, so prep makes them as the user first.
  stateDirs = [
    ".local/state/maki"
    ".local/logs/maki"
  ]
  ++ lib.optional isServer ".local/state/agent-assistant"
  ++ lib.optional isServer ".local/state/letta";

  planner = ../lib/share_planner.py;
  viewBuilder = ../lib/agent_view.py;
  python = lib.getExe pkgs.python3;

  # Asserted from the host, not the guest: a compromised guest cannot report a clean boundary.
  verifyScript = pkgs.writeShellApplication {
    name = "agent-vm-verify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.iptables
    ];
    text =
      builtins.replaceStrings
        [
          "@view@"
          "@secrets@"
          "@user@"
          "@tap@"
          "@allow@"
          "@allowRw@"
          "@hostAddr@"
          "@secretsList@"
        ]
        [
          view
          secretsDir
          user
          tap
          (lib.escapeShellArgs cfg.allow)
          (lib.escapeShellArgs cfg.allowRw)
          vmLib.hostAddr
          (lib.escapeShellArgs cfg.secrets)
        ]
        (builtins.readFile ../lib/agent-vm-verify.sh);
  };

  updateScript = pkgs.writeShellApplication {
    name = "agent-vm-update";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
      pkgs.systemd
    ];
    text =
      builtins.replaceStrings
        [
          "@expected@"
          "@key@"
          "@known@"
          "@user@"
          "@guestAddr@"
        ]
        [
          "${config.microvm.stateDir}/${name}/toplevel"
          "${stateDir}/id_ed25519"
          "${stateDir}/known_hosts"
          user
          guestAddr
        ]
        (builtins.readFile ../lib/agent-vm-update.sh);
  };

  # Host loopback services the agent uses; both are token-authenticated.
  # Host loopback services the guest reaches directly; capabilities bring their own broker.
  proxied = [ ports.llm ];
  privateNets = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/3"
  ];

  prepScript = pkgs.writeShellScript "agent-vm-prep" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.openssh
        pkgs.systemd
      ]
    }
    if [ "''${1:-}" = --reconcile ]; then
      # A switch runs this while the guest and its sessions stay up; additions appear live and
      # removals wait for the next VM start (pulling a path out from under a process is worse).
      systemctl is-active --quiet microvm@${name}.service || exit 0
      mountpoint -q ${view} || exit 0
      trap 'mount -o remount,ro ${view}' EXIT
      mount -o remount,rw ${view}
      runuser -u ${user} -- ${python} -I ${planner} --home ${home} ${plannerArgs} \
        | ${python} -I ${viewBuilder} --home ${home} --view ${view} --reconcile
      exit 0
    fi
    if mountpoint -q ${view}; then umount -R ${view}; fi
    rm -rf ${view} ${secretsDir}
    install -d -m 0711 ${runDir}
    install -d -m 0755 ${view}
    mount -t tmpfs -o mode=0755,nosuid,nodev,size=16m agent-vm-home ${view}

    # The planner shares only what exists, and the guest cannot create these under read-only
    # parents; made as the user, so no root write follows a path in the home.
    runuser -u ${user} -- mkdir -p ${lib.escapeShellArgs (map (rel: "${home}/${rel}") stateDirs)}
    ${lib.optionalString isServer ''
      # Sessions and the WebUI token sit here: no other host user may traverse.
      install -d -m 0700 -o ${user} -g users ${lib.escapeShellArg assistantState}
    ''}

    # The planner only reads the home, so it runs as its owner; the root step trusts its JSON
    # for paths alone and re-checks every source with O_NOFOLLOW.
    runuser -u ${user} -- ${python} -I ${planner} --home ${home} ${plannerArgs} \
      | ${python} -I ${viewBuilder} --home ${home} --view ${view}
    # Split dirs are tmpfs; read-only keeps the guest from leaving files beside the shares.
    # Each bind keeps its own flags.
    mount -o remount,ro ${view}

    # Root-owned so the user can read the launcher key but not swap either file for a symlink
    # that this root step would then copy into the guest.
    install -d -m 0755 -o root -g root ${stateDir}
    if [ ! -e ${stateDir}/id_ed25519 ]; then
      ssh-keygen -q -t ed25519 -N "" -C agent-vm -f ${stateDir}/id_ed25519
    fi
    chown root:root ${stateDir}/id_ed25519.pub
    chown ${user}:users ${stateDir}/id_ed25519
    chmod 0644 ${stateDir}/id_ed25519.pub
    chmod 0400 ${stateDir}/id_ed25519
    install -d -m 0755 ${secretsDir}
    install -m 0644 ${stateDir}/id_ed25519.pub ${secretsDir}/${authorizedKeys}
    # The launcher's ssh client writes this to remember the guest key; the directory stays
    # root-owned so the file cannot be swapped for a symlink into the home.
    if [ ! -e ${stateDir}/known_hosts ]; then
      install -m 0644 -o ${user} -g users /dev/null ${stateDir}/known_hosts
    fi
    for secret in ${lib.escapeShellArgs cfg.secrets}; do
      if [ -e "/run/secrets/$secret" ]; then
        install -m 0400 -o ${user} -g users "/run/secrets/$secret" "${secretsDir}/$secret"
      fi
    done
    # The memory shim always sends a bearer token; the broker replaces this placeholder.
    printf 'none' > "${secretsDir}/memory-mcp-token"
    chown ${user}:users "${secretsDir}/memory-mcp-token"
    chmod 0400 "${secretsDir}/memory-mcp-token"
  '';

  netScript = pkgs.writeShellScript "agent-vm-net" ''
    set -eu
    ${pkgs.procps}/bin/sysctl -qw net.ipv6.conf.${tap}.disable_ipv6=1
    ${pkgs.iproute2}/bin/ip addr replace ${hostAddr}/30 dev ${tap}
    ${pkgs.iproute2}/bin/ip link set ${tap} up
  '';

  # Dedicated chains jumped to from the top of INPUT/FORWARD, ahead of nixos-fw and netavark.
  # iptables-restore --noflush replaces each chain's rules in one transaction and the jumps are
  # never removed (no extraStopCommands), so a firewall restart leaves tap traffic filtered.
  rules4 = pkgs.writeText "agent-vm-rules4" ''
    *filter
    :agent-vm-in - [0:0]
    :agent-vm-fwd - [0:0]
    -A agent-vm-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ${lib.concatMapStrings (port: ''
      -A agent-vm-in -d ${hostAddr} -p tcp --dport ${toString port} -j ACCEPT
    '') (map (r: r.port) relays)}
    -A agent-vm-in -j DROP
    -A agent-vm-fwd -o ${tap} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    -A agent-vm-fwd -o ${tap} -j DROP
    ${lib.concatMapStrings (net: ''
      -A agent-vm-fwd -d ${net} -j DROP
    '') privateNets}
    -A agent-vm-fwd -j ACCEPT
    COMMIT
  '';
  rules6 = pkgs.writeText "agent-vm-rules6" ''
    *filter
    :agent-vm-in - [0:0]
    :agent-vm-fwd - [0:0]
    -A agent-vm-in -j DROP
    -A agent-vm-fwd -j DROP
    COMMIT
  '';
  firewallUp = ''
    iptables-restore -w --noflush ${rules4}
    ip6tables-restore -w --noflush ${rules6}
    for t in iptables ip6tables; do
      $t -w -C INPUT -i ${tap} -j agent-vm-in 2>/dev/null || $t -w -I INPUT 1 -i ${tap} -j agent-vm-in
      $t -w -C FORWARD -i ${tap} -j agent-vm-fwd 2>/dev/null || $t -w -I FORWARD 1 -i ${tap} -j agent-vm-fwd
      $t -w -C FORWARD -o ${tap} -j agent-vm-fwd 2>/dev/null || $t -w -I FORWARD 1 -o ${tap} -j agent-vm-fwd
    done
  '';

  proxySockets =
    prefix: listen: targetFor: relays:
    lib.listToAttrs (
      map (r: {
        name = "${prefix}-${toString r.port}";
        value = {
          socket = {
            wantedBy = [ "sockets.target" ];
            socketConfig = {
              ListenStream = "${listen}:${toString r.port}";
              # The listen address may appear after the socket unit starts (the host tap).
              FreeBind = true;
            };
          };
          service = {
            serviceConfig = {
              ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${targetFor r}";
              DynamicUser = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
            };
          };
        };
      }) relays
    );
  hostProxies =
    proxySockets "agent-vm-proxy" hostAddr (r: "127.0.0.1:${toString r.target}") relays
    // proxySockets "agent-vm-ingress" "127.0.0.1" (r: "${guestAddr}:${toString r.port}") (
      map (p: {
        port = p;
        target = p;
      }) cfg.ingressPorts
    );

  # The guest has no SSH agent: the human's ~/.ssh/config would offer YubiKey identities that
  # cannot sign there. A laptop guest reaches smortress with the personal signing key, whose
  # forced command lands in smortress's own guest (modules/nixos/ssh.nix).
  isServer = builtins.elem "server" config.machine.profiles;
  guestSshConfig = ''
    ${lib.optionalString (!isServer) ''
      Host smortress
        HostName ssh.sammohr.dev
        User ${user}
        ProxyCommand ${guestSshProxy}/bin/agent-vm-ssh-proxy
        IdentityFile /run/secrets/github-personal-signing-key
    ''}
    Host *
      IdentitiesOnly yes
      IdentityAgent none
      ForwardAgent no
      ControlMaster no
      UserKnownHostsFile /var/lib/agent-vm/known_hosts
  '';
  # Ahead of the home profile on the guest PATH (the launcher puts /run/current-system first).
  guestSsh = pkgs.writeShellScriptBin "ssh" ''
    exec ${pkgs.openssh}/bin/ssh -F /etc/agent-vm/ssh_config "$@"
  '';

  guest =
    { lib, pkgs, ... }:
    let
      guestProxies = proxySockets "agent-vm-proxy" "127.0.0.1" (
        r: "${hostAddr}:${toString r.port}"
      ) relays;
      # The runtime binds loopback; this relay is the only listener on the tap address.
      guestIngress = proxySockets "agent-vm-ingress" guestAddr (r: "127.0.0.1:${toString r.port}") (
        map (p: {
          port = p;
          target = p;
        }) cfg.ingressPorts
      );

      # Site warning lists are metadata, not story content. This drops them from the
      # generated title page; FanFicFare never put them in calibre tags.
      fanficfareIni = pkgs.writeText "fanficfare-personal.ini" ''
        [defaults]
        titlepage_entries: seriesHTML,category,genre,language,characters,ships,status,datePublished,dateUpdated,dateCreated,rating,numChapters,numWords,publisher,description

        [www.royalroad.com]
        slow_down_sleep_time:1
      '';

      # One step for agents: download into a scratch directory, then add/replace through the
      # broker-backed calibredb wrapper. Automerge keeps a re-download from duplicating a book.
      fanficfareDownload = pkgs.writeShellApplication {
        name = "fanficfare-download";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.fanficfare
        ];
        text = ''
          set -euo pipefail

          if [ $# -eq 0 ]; then
            echo "usage: fanficfare-download <story-url>..." >&2
            exit 2
          fi

          work=$(mktemp -d)
          trap 'rm -rf "$work"' EXIT

          ( cd "$work" && fanficfare -c ${fanficfareIni} "$@" )

          shopt -s nullglob
          epubs=("$work"/*.epub)
          if [ ''${#epubs[@]} -eq 0 ]; then
            echo "fanficfare-download: no EPUB written" >&2
            exit 1
          fi

          ${guestCalibre}/bin/calibredb add --automerge overwrite "''${epubs[@]}"
        '';
      };
    in
    {
      microvm = {
        hypervisor = "qemu";
        # microvm.nix otherwise loads the guest's closure into the guest's Nix DB
        # with `nix-store --load-db` on every boot. A guest `nix store gc` could then
        # unlink host-store paths the guest never owned; registering is not needed
        # because the guest reads /nix/store directly through the read-only share.
        registerClosure = false;
        # A fresh writable layer on every hypervisor start, including a crash restart: the host
        # never mounts or parses the guest's image, and guest builds reset with it. microvm.nix
        # reruns this before it recreates the missing volume.
        preStart = "rm -f nix-store.img";
        inherit (cfg) vcpu mem;
        interfaces = [
          {
            type = "tap";
            id = tap;
            mac = guestMac;
          }
        ];
        # Guest uids all write as the human: guest root cannot chown to root or plant a setuid-root
        # file in a writable tree. No --xattr (posixAcl off), so no file capabilities either.
        virtiofsd.extraArgs = [
          "--translate-uid=squash-guest:0:${toString uid}:4294967295"
          "--translate-gid=squash-guest:0:${toString gid}:4294967295"
          # virtiofsd runs as root: without CAP_MKNOD guest root cannot plant device nodes in the
          # writable trees, whose real host paths are not nodev.
          "--modcaps=-mknod"
        ];
        shares =
          map
            (
              s:
              s
              // {
                proto = "virtiofs";
                posixAcl = false;
              }
            )
            ([
              {
                tag = "ro-store";
                source = "/nix/store";
                mountPoint = "/nix/.ro-store";
                readOnly = true;
              }
              {
                tag = "home";
                source = view;
                mountPoint = home;
              }
              {
                tag = "secrets";
                source = secretsDir;
                mountPoint = "/run/secrets";
                readOnly = true;
              }
            ]);
        # Builds stay in the guest: the host daemon would run fixed-output fetches on the host's
        # own network, past the firewall below.
        writableStoreOverlay = "/nix/.rw-store";
        volumes = [
          {
            image = "var.img";
            mountPoint = "/var";
            size = 65536;
          }
          {
            image = "nix-store.img";
            mountPoint = "/nix/.rw-store";
            size = 65536;
          }
        ];
      };

      networking = {
        hostName = "agent-vm";
        useNetworkd = true;
        nameservers = [
          "1.1.1.1"
          "9.9.9.9"
        ];
        firewall.allowedTCPPorts = [ 22 ] ++ cfg.ingressPorts;
      };
      systemd.network.networks."10-tap" = {
        matchConfig.MACAddress = guestMac;
        address = [ "${guestAddr}/30" ];
        routes = [ { Gateway = hostAddr; } ];
        networkConfig.IPv6AcceptRA = false;
        linkConfig.RequiredForOnline = "routable";
      };
      boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;

      users.users.${user} = {
        inherit uid home;
        isNormalUser = true;
        group = "users";
        createHome = false;
        extraGroups = [
          "wheel"
          "docker"
        ];
      };
      # The guest is the boundary; root in it reaches nothing the user could not.
      security.sudo.wheelNeedsPassword = false;

      services.openssh = {
        enable = true;
        # /etc is rebuilt every boot; /var persists, so the launcher's known_hosts stays valid.
        hostKeys = [
          {
            path = "/var/lib/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        # A root-owned copy on the read-only secrets share, not a path in the shared home.
        authorizedKeysFiles = lib.mkForce [ "/run/secrets/${authorizedKeys}" ];
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = [ user ];
          AllowAgentForwarding = false;
          AllowTcpForwarding = "no";
          AllowStreamLocalForwarding = "no";
          X11Forwarding = false;
          PermitUserRC = false;
          AcceptEnv = [
            "COLORTERM"
            "TERM"
          ];
        };
      };

      virtualisation.docker.enable = true;
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ user ];
      };
      environment.systemPackages = [
        guestSsh
        guestCalibre
        fanficfareDownload
        sdlcGuest
        tinyfishSearch
        pkgs.gh
        pkgs.git
        pkgs.jq
        pkgs.ripgrep
        pkgs.curl
      ]
      # The assistant is a server service: the laptop guest has no ingress and no
      # always-on duty, so it gets neither the wrapper nor the unit.
      ++ lib.optionals isServer [ agentAssistant ];
      environment.etc."agent-vm/ssh_config".text = guestSshConfig;

      # Files a tool must rewrite under a read-only share get a guest-local copy bound over them.
      systemd.services =
        lib.mapAttrs (_: v: v.service) (guestProxies // guestIngress)
        // {
          agent-vm-writable = {
            wantedBy = [ "multi-user.target" ];
            after = [ "local-fs.target" ];
            before = [ "sshd.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            path = [
              pkgs.coreutils
              pkgs.util-linux
            ];
            script = lib.concatMapStrings (rel: ''
              src=${home}/${rel}
              copy=/var/lib/agent-vm/writable/${rel}
              if [ -f "$src" ] && ! mountpoint -q "$src"; then
                install -D -m 0644 -o ${user} -g users "$src" "$copy"
                mount --bind "$copy" "$src"
              fi
            '') cfg.guestWritable;
          };
        }
        // lib.optionalAttrs isServer {
          nanobot-assistant = {
            description = "nanobot assistant at agent.sammohr.dev";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "run-secrets.mount"
            ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              User = user;
              Group = "users";
              WorkingDirectory = home;
              Environment = [ "PATH=/run/wrappers/bin:/run/current-system/sw/bin" ];
              # `gateway --foreground` is the supervised runtime; `nanobot webui` is
              # an interactive client that exits when the gateway does.
              ExecStart = "${agentAssistant}/bin/agent-assistant gateway";
              Restart = "always";
              RestartSec = "5s";
              # Sessions and the token are private; the rest of the VM stays read-only.
              UMask = "0077";
              # ProtectSystem=strict makes every mount read-only, including the rw
              # shares, so reopen exactly the view's writable roots. `-` ignores a
              # root the view omitted because the host path does not exist.
              ReadWritePaths = map (r: "-${home}/${r}") cfg.allowRw;
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
                "AF_NETLINK"
              ];
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
            };
          };

          letta-assistant = {
            description = "Letta App Server at agent.sammohr.dev";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "run-secrets.mount"
            ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              User = user;
              Group = "users";
              WorkingDirectory = home;
              Environment = [ "PATH=/run/wrappers/bin:/run/current-system/sw/bin" ];
              # The wrapper pins `--backend local` and the loopback listener, so agent state
              # cannot leave the guest and the host relay is the only route in.
              ExecStart = "${agentLetta}/bin/agent-letta server";
              Restart = "always";
              RestartSec = "5s";
              UMask = "0077";
              # ProtectSystem=strict makes every mount read-only, including the rw
              # shares, so reopen exactly the view's writable roots. `-` ignores a
              # root the view omitted because the host path does not exist.
              ReadWritePaths = map (r: "-${home}/${r}") cfg.allowRw;
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
                "AF_NETLINK"
              ];
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
            };
          };
        };
      systemd.sockets = lib.mapAttrs (_: v: v.socket) (guestProxies // guestIngress);

      # Guest-local tool state: the home is a read-only view, so caches, data, gh and writable
      # copies live under /var, which is the guest's own volume.
      systemd.tmpfiles.rules = [
        "d /var/lib/agent-vm 0755 ${user} users -"
        "d /var/lib/agent-vm/cache 0755 ${user} users -"
        "d /var/lib/agent-vm/data 0755 ${user} users -"
        "d /run/agent-vm 0755 root root -"
        "C /run/agent-vm/capabilities.json 0644 root root - ${capabilityJson}"
        "C /run/agent-vm/capabilities.env 0644 root root - ${capabilityEnv}"
        "d /var/lib/agent-vm/gh 0700 ${user} users -"
        "d /var/lib/agent-vm/calibre 0755 ${user} users -"
        "f /var/lib/agent-vm/known_hosts 0644 ${user} users -"
      ];

      system.stateVersion = "26.05";
    };
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  options.agentVm = {
    allow = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Home-relative paths shared read-only; nothing else in the home is visible.";
    };
    allowRw = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Home-relative paths shared read-write; nothing else in the home is visible.";
    };
    capabilities = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.enum [
                "http"
                "tcp"
              ];
            };
            upstream = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Absolute upstream URL for an http capability.";
            };
            command = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Relay command for a tcp capability; %PORT% is the host listener.";
            };
            secret = lib.mkOption { type = lib.types.str; };
            guestPort = lib.mkOption { type = lib.types.port; };
            brokerPort = lib.mkOption {
              type = lib.types.port;
              default = 0;
              description = "Host loopback port the broker listens on; 0 reuses guestPort.";
            };
            allow = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Allowed METHOD /path pairs; empty is rejected. Use explicit METHOD /* rules when a service's route surface is intentionally open.";
            };
            env = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Guest environment variables naming this capability's endpoints.";
            };
            auth = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  kind = lib.mkOption {
                    type = lib.types.enum [
                      "bearer"
                      "header"
                      "basic"
                      "none"
                    ];
                    default = "none";
                  };
                  header = lib.mkOption {
                    type = lib.types.str;
                    default = "";
                  };
                  username = lib.mkOption {
                    type = lib.types.str;
                    default = "";
                  };
                };
              };
              default = { };
            };
          };
        }
      );
      default = { };
      description = "Guest capabilities mediated by a host broker; the secret never enters the guest.";
    };
    ingressPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Guest TCP ports the host reaches through a guest-side relay; each port needs a runtime listening on loopback in the guest.";
    };
    secrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "sops secrets (names under /run/secrets) handed to the guest at the same path.";
    };
    guestWritable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Home-relative files under read-only shares that get a guest-local writable copy.";
    };
    vcpu = lib.mkOption {
      type = lib.types.int;
      default = 4;
    };
    mem = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "Guest RAM in MiB.";
    };
  };

  config = {
    agentVm =
      lib.mapAttrs (_: lib.mkDefault) {
        allow = [
          # Skills discovery for maki; symlinks into the shared store.
          ".agents"
          # The real tool config, shared read-only; maki's pack lock is bound over separately.
          ".config/maki"
          ".config/git"
          # The manually installed maki binary; no Nix package exists yet.
          ".local/bin"
        ];
        allowRw = [
          "repos"
          "wip"
          # Shared maki sessions and logs: the host and the guest resume each other's sessions.
          ".local/state/maki"
          ".local/logs/maki"
        ]
        # nanobot sessions, pairing and the generated WebUI token; server-only.
        ++ lib.optional isServer ".local/state/agent-assistant"
        # Letta's MemFS, transcripts and provider record; server-only.
        ++ lib.optional isServer ".local/state/letta";
        # Only values that cannot be mediated stay here; every capability holds its own secret on
        # the host (see `capabilities`).
        secrets = [
          "github-personal-pat"
          "github-personal-signing-key"
        ];
        guestWritable = [ ".config/maki/pack-lock.json.lock" ];
      }
      // {
        capabilities = (
          {
            neuralwatt = {
              type = "http";
              upstream = "https://api.neuralwatt.com";
              secret = "neuralwatt-api-key";
              guestPort = ports.agentNeuralwatt;
              allow = [
                "POST /v1/chat/completions"
                "GET /v1/models"
              ];

              auth.kind = "bearer";
            };
            tinyfish = {
              type = "http";
              upstream = "https://api.search.tinyfish.ai";
              secret = "tinyfish-api-key";
              guestPort = ports.agentTinyfish;
              allow = [ "GET /" ];
              env.TINYFISH_BASE_URL = "http://127.0.0.1:${toString ports.agentTinyfish}";
              auth = {
                kind = "header";
                header = "X-API-Key";
              };
            };
            calibre = {
              type = "http";
              upstream =
                if isServer then "http://127.0.0.1:${toString ports.calibre}" else "https://calibre.sammohr.dev";
              secret = "calibre-password";
              guestPort = ports.calibre;
              brokerPort = ports.agentBrokerCalibre;
              env.CALIBRE_LIBRARY_URL = "http://127.0.0.1:${toString ports.calibre}/#books";
              # Calibre is a writable management capability by design: the broker injects
              # the human's basic-auth credential, so the Content server is not a boundary
              # against the guest. Every method the old empty list admitted (minus TRACE and
              # CONNECT) is listed here explicitly now that an empty list is rejected.
              allow = [
                "GET /*"
                "HEAD /*"
                "OPTIONS /*"
                "POST /*"
                "PUT /*"
                "PATCH /*"
                "DELETE /*"
              ];
              auth = {
                kind = "basic";
                username = "smores56";
              };
            };
          }
          // lib.optionalAttrs (!isServer) {
            smortress-ssh = {
              type = "tcp";
              secret = "cloudflare-access-ssh-token";
              guestPort = ports.agentSshRelay;
              command = "${cloudflaredAccess}/bin/cloudflared-access-host tcp --hostname ssh.sammohr.dev --url 127.0.0.1:%PORT%";
            };
          }
          // lib.optionalAttrs isServer {
            memory = {
              type = "http";
              upstream = "http://127.0.0.1:${toString ports.memoryMcp}";
              secret = "memory-mcp-token";
              guestPort = ports.memoryMcp;
              brokerPort = ports.agentBrokerMemory;
              allow = [
                "GET /mcp"
                "POST /mcp"
                "DELETE /mcp"
              ];
              auth.kind = "bearer";
            };
          }
        );
      };

    microvm.vms.${name} = {
      autostart = true;
      # A host switch must not kill running agent sessions; `agent-sandbox restart` says how to
      # pick up a changed guest.
      restartIfChanged = false;
      config = guest;
    };

    # Also the manual entry point; the unit logs a failing assertion after every prep.
    environment.systemPackages = [
      verifyScript
      updateScript
    ];
    # Apply allowlist additions to a running guest on switch; the script no-ops when the VM is
    # down and removals are deferred to the next start.
    system.activationScripts.agent-vm-reconcile = {
      deps = [ "specialfs" ];
      text = ''
        ${prepScript} --reconcile >/dev/null 2>&1 || true
      '';
    };
    systemd.services = {
      agent-vm-prep = {
        description = "Assemble the agent VM's home view and hand-in secrets";
        before = [
          "microvm-virtiofsd@${name}.service"
          "microvm@${name}.service"
        ];
        requiredBy = [ "microvm-virtiofsd@${name}.service" ];
        partOf = [ "microvm@${name}.service" ];
        # virtiofsd and the VM require this unit, so a restart here propagates to the VM and
        # drops every agent-sandbox session. The prep script is stable across host switches;
        # `agent-sandbox restart` / `sudo systemctl restart microvm@agent.service` is the
        # explicit way to re-plan the view.
        restartIfChanged = false;
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = prepScript;
          ExecStop = "-${pkgs.util-linux}/bin/umount -R ${view}";
        };
      };
      agent-vm-staleness = {
        description = "Log whether the agent guest is behind its expected closure";
        after = [
          "agent-vm-prep.service"
          "agent-vm-net.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updateScript}/bin/agent-vm-update --check";
        };
      };
      agent-vm-verify = {
        description = "Verify the agent VM's view, shares, secrets and firewall from the host";
        after = [
          "agent-vm-prep.service"
          "agent-vm-net.service"
          "firewall.service"
        ];
        requires = [ "agent-vm-prep.service" ];
        wants = [
          "agent-vm-net.service"
          "firewall.service"
        ];
        # partOf makes a prep restart re-run the assertion; the oneshot has no timer.
        partOf = [ "agent-vm-prep.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${verifyScript}/bin/agent-vm-verify";
        };
      };
      agent-vm-net = {
        description = "Address the agent VM's tap";
        after = [ "microvm-tap-interfaces@${name}.service" ];
        bindsTo = [ "microvm-tap-interfaces@${name}.service" ];
        before = [ "microvm@${name}.service" ];
        requiredBy = [ "microvm@${name}.service" ];
        # Same propagation: the VM requires this unit, so a host-switch restart would stop the
        # guest. The tap address is stable; `microvm@agent` restart re-applies it.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = netScript;
        };
      };
    }
    // lib.mapAttrs (_: v: v.service) hostProxies
    // brokerServices;
    systemd.timers."agent-vm-staleness" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "15min";
      };
    };
    systemd.sockets = lib.mapAttrs (_: v: v.socket) hostProxies;

    assertions = [
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "agent-vm isolates the tap with iptables firewall extraCommands";
      }
      {
        assertion = lib.all (
          pair: lib.elem (lib.removePrefix "/run/secrets/" (lib.last (lib.splitString "|" pair))) cfg.secrets
        ) vmLib.secretEnv;
        message = "agent-vm: every secret the launcher exports must be in agentVm.secrets";
      }
      {
        assertion =
          config.systemd.services."agent-vm-prep".restartIfChanged == false
          && config.systemd.services."agent-vm-net".restartIfChanged == false;
        message = "agent-vm: prep/net must not restart on host switch; they are requiredBy the VM and would drop every session";
      }
      {
        assertion =
          !(config ? webProxy && config.webProxy.services ? agent)
          || lib.elem config.webProxy.services.agent.port cfg.ingressPorts;
        message = "agent-vm: webProxy.services.agent.port must be in agentVm.ingressPorts, or the tunnel points at a port with no guest relay";
      }
      {
        assertion = lib.all (c: c.type != "http" || c.allow != [ ]) (lib.attrValues cfg.capabilities);
        message = "agent-vm: every http capability needs a non-empty allow list";
      }
    ];

    # microvm.nix allows qemu-bridge-helper onto every bridge; this VM uses a plain tap.
    environment.etc."qemu/bridge.conf".text = "deny all\n";

    networking = {
      nat = {
        enable = true;
        internalInterfaces = [ tap ];
      };
      networkmanager.unmanaged = [ tap ];
      firewall = {
        extraCommands = firewallUp;
      };
    };
  };
}
