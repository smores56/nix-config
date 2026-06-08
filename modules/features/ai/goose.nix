{
  config,
  lib,
  pkgs,
  aiXiaomi,
  aiDeepseek,
  ...
}:
let
  cfg = config.dotfiles.goose;
  enabled = cfg.enable;
  homeDir = config.home.homeDirectory;
  configDir = "${homeDir}/.config/goose";

  mkProviderJSON = providerId: displayName: baseUrl: apiKeyEnv: engine: models: ''
    {
      "name": "${providerId}",
      "display_name": "${displayName}",
      "engine": "${engine}",
      "api_key_env": "${apiKeyEnv}",
      "base_url": "${baseUrl}",
      "models": ${builtins.toJSON models},
      "supports_streaming": true,
      "requires_auth": true
    }
  '';

  xiaomiModels = map (m: {
    name = m.id;
    context_limit = m.context;
    reasoning = m.reasoning;
  }) aiXiaomi.selectedModels;

  deepseekModels = map (m: {
    name = m.id;
    context_limit = m.context;
    reasoning = m.reasoning;
  }) aiDeepseek.selectedModels;

  xiaomiProviderJSON = mkProviderJSON
    "xiaomi"
    "Xiaomi MiMo"
    aiXiaomi.baseUrl
    "XIAOMI_MIMO_API_KEY"
    "openai"
    xiaomiModels;

  deepseekProviderJSON = mkProviderJSON
    "deepseek"
    "DeepSeek"
    aiDeepseek.baseUrl
    "DEEPSEEK_API_KEY"
    "openai"
    deepseekModels;

  secretKeyFile = "${configDir}/server-secret";

  gooseIcon = size: pkgs.runCommand "goose-icon-${toString size}.png"
    {
      nativeBuildInputs = [ pkgs.imagemagick ];
    } ''
    convert -size ${toString size}x${toString size} \
      -define 'gradient:radii=256,256' \
      'radial-gradient:#3b82f6-#1d4ed8' \
      -fill white -font Helvetica-Bold -pointsize ${toString (size / 3)} -gravity center \
      -annotate 0 '🪿' \
      $out
  '';

  webDir = pkgs.runCommand "goose-web-dir" { } ''
    mkdir $out
    cp ${./goose-web/index.html} $out/index.html
    cp ${./goose-web/manifest.json} $out/manifest.json
    cp ${./goose-web/sw.js} $out/sw.js
    cp ${gooseIcon 192} $out/icon-192.png
    cp ${gooseIcon 512} $out/icon-512.png
  '';

in
{
  config = lib.mkIf enabled {
    home.packages = [ pkgs.goose-cli ];

    home.file."${configDir}/custom_providers/xiaomi.json".text = xiaomiProviderJSON;
    home.file."${configDir}/custom_providers/deepseek.json".text = deepseekProviderJSON;

    # ── goosed agent server ─────────────────────────
    systemd.user.services.goosed = lib.mkIf cfg.server.enable {
      Unit = {
        Description = "goosed — Goose agent server";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        ExecStartPre = pkgs.writeShellScript "goose-server-secret" ''
          if [ ! -f "${secretKeyFile}" ]; then
            ${pkgs.openssl}/bin/openssl rand -hex 32 > "${secretKeyFile}"
            chmod 600 "${secretKeyFile}"
          fi
        '';
        ExecStart = "${pkgs.goose-cli}/bin/goosed agent";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = {
          HOME = "%h";
          GOOSE_SERVER__SECRET_KEY = "$(cat ${secretKeyFile})";
        };
      };
      Install = { WantedBy = [ "default.target" ]; };
    };

    # ── goose-web PWA ───────────────────────────────
    systemd.user.services.goose-web = lib.mkIf cfg.web.enable {
      Unit = {
        Description = "goose-web — Goose PWA";
        After = [ "network-online.target" "goosed.service" ];
        Wants = [ "network-online.target" ];
        BindsTo = [ "goosed.service" ];
      };
      Service = {
        ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${webDir} --addr 127.0.0.1 --port ${toString cfg.web.port} --no-listing";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install = { WantedBy = [ "default.target" ]; };
    };

    programs.fish.shellAbbrs = {
      gs = "goose session";
      gr = "goose run";
      gc = "goose configure";
    };
  };
}
