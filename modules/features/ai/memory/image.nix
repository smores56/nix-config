# The in-cluster wrapper image. One process, no shell tooling beyond what the
# package already wraps in: the Deployment runs it as uid 1000 with a mounted
# state dir and cluster DNS names in its environment.
#
# Publish with `just publish-memory-image <tag>`; the printed digest is the only
# thing that enters smores56/homelabs-platform. The tag inside this archive is
# irrelevant — skopeo renames it at push time.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  memory = import ./package.nix { inherit pkgs lib; };
in
pkgs.dockerTools.buildLayeredImage {
  name = "memory-mcp";
  tag = "dev";

  contents = [
    memory
    # TLS roots for anything httpx dials over https (the wrapper itself talks plain
    # HTTP to Graphiti; keep the store path so a future endpoint does not fail oddly).
    pkgs.cacert
    pkgs.bashInteractive
  ];

  config = {
    Entrypoint = [ "${memory}/bin/memory-mcp" ];
    # No WORKDIR: the pod sets its own writable path, and a cwd that does not exist
    # in the image makes runc fail before the process starts (readOnlyRootFilesystem
    # cannot create it either).
    WorkingDirectory = "/";
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "PYTHONUNBUFFERED=1"
      # No shell profile is read in a pod; keep the package's PATH wrapper meaningful.
      "PATH=${memory}/bin"
    ];
  };
}
