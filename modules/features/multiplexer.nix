{ config, ... }:
{
  programs.zellij = {
    enable = true;
    enableFishIntegration = false;

    settings = {
      default_shell = config.dotfiles.shellPath;
      theme = "tinted";
      ui.pane_frames.rounded_corners = true;
      session_serialization = false;
      show_startup_tips = false;
    };
  };
}
