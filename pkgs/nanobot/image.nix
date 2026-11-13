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
    Entrypoint = [ "${nanobot}/bin/nanobot" ];
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
