{
  config,
  lib,
  pkgs,
  ...
}:
let
  isWork = config.dotfiles.work.enable;

  gleanServerUrl = "https://sevenai-be.glean.com";
  glean = {
    command = "npx";
    args = [
      "-y"
      "@gleanwork/local-mcp-server"
    ];
    env = {
      GLEAN_SERVER_URL = gleanServerUrl;
      GLEAN_API_TOKEN = "\${GLEAN_API_TOKEN}";
    };
  };

  slack = {
    command = "sh";
    args = [
      "-lc"
      ''
        cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/slack-mcp-server"
        mkdir -p "$cache_dir"
        export SLACK_MCP_USERS_CACHE="$cache_dir/users_cache.json"
        export SLACK_MCP_CHANNELS_CACHE="$cache_dir/channels_cache_v2.json"
        exec ${pkgs.nodejs}/bin/node ${./mcp-schema-sanitizer.mjs} npx -y slack-mcp-server@latest --transport stdio
      ''
    ];
  };

  workMcpServers = lib.optionalAttrs isWork {
    inherit glean slack;
  };
in
{
  options.dotfiles.ai.mcpServers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
    readOnly = true;
    description = "Shared MCP server definitions for AI coding agents.";
  };

  config.dotfiles.ai.mcpServers = workMcpServers;
}
