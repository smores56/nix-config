# photobucket: keyboard-driven photo triage. Photos are reviewed one at a time
# in feh; keys 1-9 only *record* a decision in the session's decisions.tsv.
# Nothing moves on keystroke, so a stray tap is undoable in-session (`undo` pops
# the last log line); bulk relocating happens later via `apply`, which moves
# each decided file into bucket 01-09 and records it in applied.tsv.
# WHY slideshow mode: in feh 3.12.2 normal mode an action triggers
# `winwidget_destroy` (the window closes), but slideshow mode runs the action
# and then unconditionally advances to the next image. So the viewer passes
# `--slideshow-delay` (a huge delay) to keep number-key actions usable; the
# actions themselves need not move anything. See photobucket.py.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  cfg = config.dotfiles.photobucket;
  root = if cfg.root == "" then "${config.home.homeDirectory}/Pictures/_triage" else cfg.root;
  photobucket = pkgs.writeShellScriptBin "photobucket" ''
    export PHOTOBUCKET_ROOT=${lib.escapeShellArg root}
    exec ${pkgs.python3}/bin/python3 ${./photobucket.py} "$@"
  '';
in
{
  config = lib.mkIf (isLinux && cfg.enable) {
    home.packages = [
      pkgs.feh
      photobucket
    ];
  };
}
