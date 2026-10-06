# immich-ingest: pre-import capture-time normalisation and upload for Google
# Takeout dumps. The Python helper reuses photobucket.py's media detection and
# filename parser, so both files are shipped to the store; the env var points at
# the latter.
{
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  immich-ingest = pkgs.writeShellScriptBin "immich-ingest" ''
    export IMMICH_INGEST_PHOTOBUCKET=${./../photobucket/photobucket.py}
    exec ${pkgs.python3}/bin/python3 ${./immich_ingest.py} "$@"
  '';
in
{
  config = lib.mkIf isLinux {
    home.packages = [ immich-ingest ];
  };
}
