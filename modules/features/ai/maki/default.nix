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
in
{
  config = lib.mkIf enabled {
    home.packages =
      (lib.optionals cfg.rtk.enable [ pkgs.rtk ])
      ++ (lib.optionals cfg.monty.enable [ pkgs.python313Packages.pydantic-monty ]);

    # Disable maki's built-in memory plugin
    home.file.".config/maki/init.lua".text = ''
      maki.setup({
          tools = {
              memory = { enabled = false },
          },
      })
    '';

    # Usage guidance for the model (replaces built-in memory prompt nudge)
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

    # CrofAI dynamic provider script
    home.file.".config/maki/providers/crofai" = {
      source = ./providers/crofai;
      executable = true;
    };

    # Mem0 MCP server script (symlinked from Nix store)
    home.file.".local/share/maki-mem0/mem0_mcp_server.py" = lib.mkIf cfg.mem0.enable {
      source = ./mem0_mcp_server.py;
    };

    # Mem0 MCP server registration (only if mem0 enabled)
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

    # Python venv creation and pip install for mem0 dependencies
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

    programs.fish.shellAbbrs = {
      mk = "maki";
    };
  };
}
