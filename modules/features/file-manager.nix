{ config, lib, ... }:
{
  programs.yazi = lib.mkIf (!builtins.elem "yazi" config.user.dotfilesOwns) {
    enable = true;

    settings.mgr.sort_by = "natural";
  };
}
