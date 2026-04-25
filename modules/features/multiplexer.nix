{ config, pkgs, ... }:
let
  shellBin = "${pkgs.${config.dotfiles.shell}}/bin/${config.dotfiles.shell}";
in
{
  programs.zellij = {
    enable = true;
    enableFishIntegration = false;

    settings = {
      default_shell = shellBin;
      theme = "tinted";
      ui.pane_frames.rounded_corners = true;
      session_serialization = false;
      show_startup_tips = false;
    };
  };
}
