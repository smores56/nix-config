{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateDir = "${config.dotfiles.codeRoot}/github.com/smores56/sdlc-state";

  # Bundle the CLI sources into one store dir so sibling imports resolve
  # (each `${./file}` alone would land in its own store path).
  sdlcSrc = pkgs.runCommand "sdlc-src" { } ''
    mkdir -p $out
    cp ${./sdlc_cli.py} $out/sdlc_cli.py
    cp ${./sdlc_model.py} $out/sdlc_model.py
    cp ${./sdlc_state.py} $out/sdlc_state.py
  '';

  sdlcBin = pkgs.writeShellScriptBin "sdlc" ''
    export SDLC_STATE_DIR=''${SDLC_STATE_DIR:-${lib.escapeShellArg stateDir}}
    export PYTHONPATH=${sdlcSrc}
    exec ${pkgs.python3}/bin/python3 ${sdlcSrc}/sdlc_cli.py "$@"
  '';
in
{
  home.packages = [ sdlcBin ];

  home.file.".config/television/cable/features.toml".source = ./features.toml;

  programs.fish.shellAbbrs = {
    sf = "tv features | read -l f; and c $f";
    sfe = "tv features | read -l f; and sdlc edit (string replace -r '^.*/' '' $f) plan";
    sfl = "sdlc list";
  };
}
