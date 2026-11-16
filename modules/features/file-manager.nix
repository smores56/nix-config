{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.packages = lib.optional (builtins.elem "yazi" config.user.dotfilesOwns) pkgs.yazi;

  programs.yazi = lib.mkIf (!builtins.elem "yazi" config.user.dotfilesOwns) {
    enable = true;

    settings.mgr.sort_by = "natural";
  };
}
