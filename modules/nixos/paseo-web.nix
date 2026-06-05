{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  d = config.dotfiles;
  inherit (lib) mkIf;

  cfg = d.paseo;
  webCfg = cfg.web or { };
  enabled = cfg.enable && webCfg.enable;

  paseoWebPkg = pkgs.callPackage ../packages/paseo-web.nix {
    paseoSrc = inputs.paseo;
    paseoVersion = (builtins.fromJSON (builtins.readFile "${inputs.paseo}/package.json")).version;
    npmDeps = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.default.npmDeps;
  };
in
{
  config = mkIf enabled {
    services.caddy = {
      enable = true;
      virtualHosts.":${toString webCfg.port}" = {
        extraConfig = ''
          @api {
            path /api/*
          }

          handle @api {
            reverse_proxy 127.0.0.1:6767
          }

          @ws {
            path /ws*
          }

          handle @ws {
            reverse_proxy 127.0.0.1:6767
          }

          handle {
            root * ${paseoWebPkg}
            try_files {path} /index.html
            file_server
          }
        '';
      };
    };

    networking.firewall.allowedTCPPorts = [ webCfg.port ];
  };
}
