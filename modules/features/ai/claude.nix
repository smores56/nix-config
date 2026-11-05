# Claude Code is installed outside Nix and rewrites its own settings, so the declarative parts
# are merged key by key at activation: auto-memory off (the memory service is the only memory)
# and the MCP servers hosts register through `ai.claude.mcpServers`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  claudeConfig = pkgs.writeShellApplication {
    name = "claude-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.jq
    ];
    text = ''
      servers=''${1:?usage: claude-config <servers.json>}

      # Rewrites $1 through jq only when the result differs, so reruns leave mtimes alone.
      merge() {
        local file=$1 tmp
        shift
        [ -e "$file" ] || echo '{}' >"$file"
        tmp=$(mktemp "$file.XXXXXX")
        if ! jq "$@" "$file" >"$tmp"; then
          rm -f "$tmp"
          echo "claude-config: cannot merge into $file" >&2
          return 1
        fi
        if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else mv "$tmp" "$file"; fi
      }

      mkdir -p "$HOME/.claude"
      merge "$HOME/.claude/settings.json" '.autoMemoryEnabled = false'

      if [ "$(jq 'length' "$servers")" -gt 0 ]; then
        # shellcheck disable=SC2016 # jq variables
        merge "$HOME/.claude.json" --slurpfile s "$servers" '.mcpServers = ((.mcpServers // {}) + $s[0])'
      fi
    '';
  };

  serversFile = pkgs.writeText "claude-mcp-servers.json" (
    builtins.toJSON config.ai.claude.mcpServers
  );
in
{
  options.ai.claude.mcpServers = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = { };
    description = "Claude Code user-scope MCP servers, merged into ~/.claude.json by name.";
  };

  config = {
    home.packages = [ claudeConfig ];

    home.activation.claudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe claudeConfig} ${serversFile} || true
    '';
  };
}
