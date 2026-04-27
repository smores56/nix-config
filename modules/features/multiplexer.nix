{ config, ... }:
{
  programs.zellij = {
    enable = true;
    enableFishIntegration = false;
  };
}
