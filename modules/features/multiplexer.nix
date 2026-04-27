{ config, ... }:
{
  programs.zellij = {
    enable = true;
    enableFishIntegration = false;

    settings = {
      default_shell = config.dotfiles.shellPath;
      ui.pane_frames.rounded_corners = true;
      session_serialization = false;
      show_startup_tips = false;
    };
  };
}
