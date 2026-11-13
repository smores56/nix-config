# The in-cluster agent image: nanobot's virtualenv plus the tools its skills and
# the T8 acceptance script need. The pod supplies the args
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
  entrypoint = pkgs.writeShellScript "nanobot-entrypoint" ''
    set -eu
    home="''${HOME:-/data/home}"
    ${nanobot}/bin/python ${./render.py}
    exec ${nanobot}/bin/nanobot "$@"
  '';
  # One list feeds both the image's /bin and PATH. A tool added to only one of
  # the two is invisible to the exec tool, so add it here and nowhere else.
  # Deliberately absent: kubectl (the agent has no cluster credentials) and
  # nodejs (no skill needs it).
  tools = [
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.curl
    pkgs.diffutils
    pkgs.fd
    pkgs.findutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gnutar
    pkgs.gzip
    pkgs.jq
    pkgs.kustomize
    pkgs.ripgrep
    pkgs.yq-go
  ];
in
pkgs.dockerTools.buildLayeredImage {
  name = "nanobot";
  tag = "dev";

  contents = [ nanobot pkgs.cacert ] ++ tools;

  config = {
    Entrypoint = [ "${entrypoint}" ];
    WorkingDirectory = "/";
    # A CLI push links the GHCR package to this repository only when the image
    # carries the source label.
    Labels."org.opencontainers.image.source" = "https://github.com/smores56/nix-config";
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "PYTHONUNBUFFERED=1"
      "PATH=${lib.makeBinPath ([ nanobot ] ++ tools)}"
    ];
  };
}
