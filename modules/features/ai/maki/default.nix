{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.maki;
  enabled = cfg.enable;

  homeDir = config.home.homeDirectory;
  makiHome = "${homeDir}/.local/share/maki-mem0";
  venvPython = "${makiHome}/venv/bin/python";
  serverScript = "${makiHome}/mem0_mcp_server.py";
  chromaDir = "${makiHome}/chroma";

  makiExtrasDir = "${homeDir}/code/github.com/smores56/maki-extras";
in
{
  config = lib.mkIf enabled {
    home.packages = with pkgs; [
      cloudflared
    ] ++ (lib.optionals cfg.rtk.enable [ pkgs.rtk ])
      ++ (lib.optionals cfg.monty.enable [ pkgs.python313Packages.pydantic-monty ]);

    # ── maki agent config ──────────────────────────

    home.file.".config/maki/init.lua".text = ''
      maki.setup({
          tools = {
              memory = { enabled = false },
          },
          provider = {
              default_model = "ds/deepseek-v4-pro",
          },
      })
    '';

    home.file.".config/maki/AGENTS.md".text = ''
      ## Long-term memory (mem0)

      You have a persistent, project-scoped memory via the `mem0__*` tools. Use it:

      - **Before** starting non-trivial work, call `mem0__search_memory` with a focused
        query to retrieve relevant prior context (conventions, architecture decisions, gotchas).
      - **After** learning something durable — a non-obvious gotcha, an architecture decision,
        a user preference, a project convention — call `mem0__add_memory` with a concise entry.
      - Use `mem0__list_memories` to review, and `mem0__delete_memory` to remove stale entries.
      - Keep entries short and current. Do not store transient or trivial details.
    '';

    home.file.".config/maki/providers/ds" = {
      source = ./providers/ds;
      executable = true;
    };

    # ── Mem0 MCP server ────────────────────────────

    home.file.".local/share/maki-mem0/mem0_mcp_server.py" = lib.mkIf cfg.mem0.enable {
      source = ./mem0_mcp_server.py;
    };

    home.file.".config/maki/mcp.toml" = lib.mkIf cfg.mem0.enable {
      text = ''
        [mcp.mem0]
        command = [
            "${venvPython}",
            "${serverScript}",
        ]
        environment = { OLLAMA_HOST = "http://127.0.0.1:11434" }
        timeout = 60000
      '';
    };

    home.activation.installMem0Shim = lib.mkIf cfg.mem0.enable (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        export UV_NO_CONFIG=1
        export PATH="${lib.makeBinPath [ pkgs.python313 ]}:$PATH"

        if [ -x "${venvPython}" ]; then
          echo "[maki] mem0 venv already present at ${makiHome}/venv"
        else
          echo "[maki] creating mem0 venv at ${makiHome}/venv…"
          mkdir -p "${makiHome}"
          python3 -m venv "${makiHome}/venv"
        fi

        echo "[maki] installing mem0ai, mcp, chromadb…"
        "${venvPython}" -m pip install --quiet --upgrade "mem0ai" "mcp" "chromadb" \
          || echo "[maki] pip install failed (may need network: retry later with '${venvPython} -m pip install mem0ai mcp chromadb')" >&2

        mkdir -p "${chromaDir}"
      ''
    );

    # ── maki-serve systemd user service ────────────
    # Binary must be installed first: cd maki-extras && just install

    systemd.user.services.maki-serve = {
      Unit = {
        Description = "maki-serve daemon — HTTP+SSE API for maki agent";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "${homeDir}/.cargo/bin/maki-serve";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = "RUST_LOG=info";
      };
      Install = { WantedBy = [ "default.target" ]; };
    };

    # ── cloudflared tunnel → maki.sammohr.dev ──────

    systemd.user.services.cloudflared-maki = {
      Unit = {
        Description = "cloudflared tunnel — maki.sammohr.dev";
        After = [ "network-online.target" "maki-serve.service" ];
        Wants = [ "network-online.target" ];
        BindsTo = [ "maki-serve.service" ];
      };
      Service = {
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel run --url http://localhost:8080 maki";
        Restart = "on-failure";
        RestartSec = 10;
        Environment = "HOME=%h";
      };
      Install = { WantedBy = [ "default.target" ]; };
    };

    # ── shell ──────────────────────────────────────

    programs.fish.shellAbbrs = {
      mk = "maki";
      ms = "cd ${makiExtrasDir} && just serve";
      mo = "cd ${makiExtrasDir} && just orchestrator";
    };
  };
}
