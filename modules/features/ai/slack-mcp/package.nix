{ pkgs }:
let
  backend = import ./backend.nix { inherit pkgs; };
  scripts = pkgs.runCommand "maki-slack-scripts" { } ''
    mkdir -p "$out"
    cp ${./session.mjs} "$out/session.mjs"
    cp ${./leveldb.mjs} "$out/leveldb.mjs"
  '';
in
pkgs.writeShellApplication {
  name = "maki-slack";
  text = ''
    unset NODE_OPTIONS NODE_DEBUG NODE_DEBUG_NATIVE
    if [ "''${1:-}" = serve ]; then
      shift
      if [ "$#" -ne 0 ]; then
        printf 'usage: maki-slack serve\n' >&2
        exit 1
      fi
      exec ${pkgs.nodejs_24}/bin/node ${scripts}/session.mjs serve --backend ${backend}/bin/slack-mcp-server
    fi
    exec ${pkgs.nodejs_24}/bin/node ${scripts}/session.mjs "$@"
  '';
}
