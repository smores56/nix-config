# The one `sdlc` CLI: the host profile and the agent VM install the same wrapper.
{ pkgs }:
pkgs.writeShellScriptBin "sdlc" ''
  exec ${pkgs.python3}/bin/python3 ${../features/ai/sdlc/sdlc_issues.py} "$@"
''
