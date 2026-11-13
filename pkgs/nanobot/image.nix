# The in-cluster agent image: nanobot's virtualenv plus the tools its skills and
# the T8 acceptance script need (git, curl). The pod supplies the args
# (`gateway --foreground`), the config tree at NANOBOT_CONFIG_DIR, HOME on the
# scratch PVC, and the broker environment; the image sets none of those.
{
  pkgs,
  lib ? pkgs.lib,
  inputs,
}:
let
  # `packages`' pkgs has no project overlay, so build the environment here.
  nanobot = pkgs.callPackage ./default.nix { inherit inputs; };
  # The gateway binds loopback unless config.gateway.host says otherwise, and
  # nanobot ships the docker bootstrap that writes exactly that (plus the web
  # token). Run it once per HOME, then exec the CLI unchanged so the pod's args
  # stay `gateway --foreground --port 8080`.
  configure = pkgs.writeText "nanobot-configure.py" ''
    import json
    import sys
    from pathlib import Path

    path = Path(sys.argv[1])
    if not path.exists():
        from nanobot.cli.docker_bootstrap import initialize_config
        initialize_config(path)
    config = json.loads(path.read_text())
    # The gateway and the websocket channel default to loopback; the pod is
    # reached through the tunnel, so both must listen on every interface.
    config.setdefault("gateway", {})["host"] = "0.0.0.0"
    websocket = config.setdefault("channels", {}).setdefault("websocket", {})
    websocket["host"] = "0.0.0.0"
    path.write_text(json.dumps(config, indent=2) + "\n")
  '';
  entrypoint = pkgs.writeShellScript "nanobot-entrypoint" ''
    set -eu
    home="''${HOME:-/data/home}"
    ${nanobot}/bin/python ${configure} "$home/.nanobot/config.json"
    exec ${nanobot}/bin/nanobot "$@"
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = "nanobot";
  tag = "dev";

  contents = [
    nanobot
    pkgs.cacert
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.git
    pkgs.curl
  ];

  config = {
    Entrypoint = [ "${entrypoint}" ];
    WorkingDirectory = "/";
    # A CLI push links the GHCR package to this repository only when the image
    # carries the source label.
    Labels."org.opencontainers.image.source" = "https://github.com/smores56/nix-config";
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "PYTHONUNBUFFERED=1"
      "PATH=${
        lib.makeBinPath [
          nanobot
          pkgs.coreutils
          pkgs.git
          pkgs.curl
          pkgs.bashInteractive
        ]
      }"
    ];
  };
}
