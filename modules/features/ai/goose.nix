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
      'radial-gradient:#3b82f6-#1d4ed8' \
      -fill none -stroke white -strokewidth ${toString (size / 8)} \
      -draw "circle ${toString (size / 2)},${toString (size / 2)} ${toString (size / 2)},${toString (size / 4)}" \
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

  # Caddy reverse proxy: serves PWA at / and proxies API calls to goosed on :3000.
  # Disables admin API to avoid port conflicts. The X-Secret-Key is injected
  # server-side so the PWA never needs to handle it.
  caddyConfig = pkgs.writeText "goose-caddy.json" (builtins.toJSON {
    admin = { disabled = true; };
    apps.http.servers.goose = {
      listen = [ "127.0.0.1:${toString cfg.web.port}" ];
      routes = [
        {
          match = [{
            path = [
              "/reply" "/sessions" "/sessions/*"
              "/status" "/setup" "/setup/*"
              "/config/*" "/agent/*" "/gateway/*"
              "/tunnel/*" "/mcp_ui_proxy/*" "/mcp_app_proxy/*"
              "/prompts/*" "/recipe/*" "/schedule/*"
              "/telemetry/*" "/dictation/*" "/action_required/*"
              "/sampling/*"
            ];
          }];
          handle = [{
            handler = "reverse_proxy";
            upstreams = [{ dial = "127.0.0.1:3000"; }];
            transport = {
              protocol = "http";
              tls = {
                insecure_skip_verify = true;
              };
            };
            headers = {
              request = {
                set = {
                  "X-Secret-Key" = [ "{env.GOOSE_SERVER_SECRET}" ];
                };
              };
            };
          }];
        }
        {
          handle = [{
            handler = "file_server";
            root = webDir;
          }];
        }
      ];
    };
  });

in
{
  config = lib.mkIf enabled {
    home.packages = [ pkgs.goose-cli pkgs.caddy ];

    home.file."${configDir}/custom_providers/xiaomi.json".text = xiaomiProviderJSON;
    home.file."${configDir}/custom_providers/deepseek.json".text = deepseekProviderJSON;

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
        ExecStart = pkgs.writeShellScript "goosed-start" ''
          export GOOSE_SERVER__SECRET_KEY="$(cat ${secretKeyFile})"
          exec ${pkgs.goose-cli}/bin/goosed agent
        '';
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "HOME=%h"
        ];
      };
      Install = { WantedBy = [ "default.target" ]; };
    };

    systemd.user.services.goose-web = lib.mkIf cfg.web.enable {
      Unit = {
        Description = "goose-web — Goose PWA + API reverse proxy";
        After = [ "network-online.target" "goosed.service" ];
        Wants = [ "network-online.target" ];
        Requires = [ "goosed.service" ];
      };
      Service = {
        ExecStart = pkgs.writeShellScript "goose-caddy-start" ''
          export GOOSE_SERVER_SECRET="$(cat ${secretKeyFile})"
          exec ${pkgs.caddy}/bin/caddy run --config ${caddyConfig}
        '';
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "HOME=%h"
        ];
      };
      Install = { WantedBy = [ "default.target" ]; };
    };

    programs.fish.shellAbbrs = {
      go = "goose session";
      gor = "goose run";
      goc = "goose configure";
    };
  };
}
