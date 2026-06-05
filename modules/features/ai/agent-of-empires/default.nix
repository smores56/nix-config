{ config, lib, pkgs, ... }:
let
  cfg = config.dotfiles.agentOfEmpires;

  aoeConfig = pkgs.writeText "aoe-config.toml" ''
    [session]
    default_tool = "pi"

    custom_agents = { "pi" = "pi" }

    [sandbox]
    enabled_by_default = true
    default_image = "ghcr.io/agent-of-empires/aoe-sandbox:latest"
    auto_cleanup = true
    cpu_limit = "4"
    memory_limit = "8g"
    environment = [
      "ANTHROPIC_API_KEY",
      "OPENAI_API_KEY",
      "DEEPSEEK_API_KEY",
    ]
    volume_ignores = ["node_modules", ".venv", "target"]

    [worktree]
    enabled = true
    auto_cleanup = true
  '';
in
{
  config = lib.mkIf cfg.enable {
    home.file.".config/agent-of-empires/config.toml".source = aoeConfig;

    systemd.user.services.aoe-serve = {
      Unit = {
        Description = "Agent of Empires web dashboard";
        After = [ "network-online.target" "docker.service" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${config.home.homeDirectory}/.local/bin/aoe serve --port ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
