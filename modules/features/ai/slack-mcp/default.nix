{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.slackMcp;
  package = import ./package.nix { inherit pkgs; };
  settings = pkgs.formats.toml { };
in
{
  options.slackMcp.enable = lib.mkEnableOption "the Keychain-backed, read-only Slack desktop connector for work Maki";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin && config.user.aiProfile == "work";
        message = "slackMcp requires macOS and an explicitly selected work AI profile.";
      }
    ];

    home.packages = [ package ];
    home.file = {
      ".config/maki/mcp.toml".source = settings.generate "maki-slack-mcp.toml" {
        mcp.slack = {
          command = [
            "${package}/bin/maki-slack"
            "serve"
          ];
          timeout = 120000;
          enabled = true;
        };
      };
      ".agents/skills/native-slack".source = ./skill;
    };
  };
}
