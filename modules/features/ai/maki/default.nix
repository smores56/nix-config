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

  modelsJSON = if cfg.models == [ ] then null else lib.escapeNixString (builtins.toJSON cfg.models);
in
{
  config = lib.mkIf enabled {
    home.packages =
      with pkgs;
      [
        cloudflared
      ]
      ++ (lib.optionals cfg.rtk.enable [ pkgs.rtk ])
      ++ (lib.optionals cfg.monty.enable [ pkgs.python313Packages.pydantic-monty ]);

    # ── maki agent config ──────────────────────────
    home.file.".config/maki/init.lua".text = ''
      maki.setup({
          tools = { memory = { enabled = false } },
          provider = { default_model = "${cfg.defaultModel}" },
      })
    '';
    home.file.".config/maki/AGENTS.md".text = ''
      ## Long-term memory (mem0)
      You have a persistent, project-scoped memory via the `mem0__*` tools. Use it:
      - **Before** starting non-trivial work, call `mem0__search_memory`.
      - **After** learning something durable, call `mem0__add_memory`.
      - Keep entries short and current. Do not store transient or trivial details.
    '';
    home.file.".config/maki/providers/ds" = {
      source = ./providers/ds;
      executable = true;
    };

    # ── models.json (served via GET /api/models for web UI model picker) ──
    home.file.".config/maki/providers/crofai" = {
      source = ./providers/crofai;
      executable = true;
    };

    # ── models.json (served via GET /api/models for web UI model picker) ──
    home.file.".config/maki/models.json" = lib.mkIf (cfg.models != [ ]) {
      text = builtins.toJSON cfg.models;
    };

    # ── Mem0 MCP ───────────────────────────────────
    home.file.".local/share/maki-mem0/mem0_mcp_server.py" = lib.mkIf cfg.mem0.enable {
      source = ./mem0_mcp_server.py;
    };
    home.file.".config/maki/mcp.toml" = lib.mkIf cfg.mem0.enable {
      text = ''
        [mcp.mem0]
        command = ["${venvPython}", "${serverScript}"]
        environment = { OLLAMA_HOST = "http://127.0.0.1:11434" }
        timeout = 60000
      '';
    };
    home.activation.installMem0Shim = lib.mkIf cfg.mem0.enable (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        export UV_NO_CONFIG=1
        export PATH="${lib.makeBinPath [ pkgs.python313 ]}:$PATH"
        if [ -x "${venvPython}" ]; then
          echo "[maki] mem0 venv already present"
        else
          echo "[maki] creating mem0 venv…"
          mkdir -p "${makiHome}"
          python3 -m venv "${makiHome}/venv"
        fi
        echo "[maki] installing mem0ai, mcp, chromadb…"
        "${venvPython}" -m pip install --quiet --upgrade "mem0ai" "mcp" "chromadb" \
          || echo "[maki] pip install failed (retry manually)" >&2
        mkdir -p "${chromaDir}"
      ''
    );

    # ── maki-serve systemd user service ────────────
    # Requires: cd maki-extras && just install
    systemd.user.services.maki-serve = {
      Unit = {
        Description = "maki-serve — HTTP+SSE daemon for maki agent";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "${homeDir}/.cargo/bin/maki-serve";
        Restart = "on-failure";
        RestartSec = 5;
        EnvironmentFile = "%h/.config/maki/env";
        Environment = "RUST_LOG=info";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    # ── shell ──────────────────────────────────────
    programs.fish.shellAbbrs = {
      mk = "maki";
      ms = "cd ${makiExtrasDir} && just serve";
      mo = "cd ${makiExtrasDir} && just orchestrator";
    };
  };
}
