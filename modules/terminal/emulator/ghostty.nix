{ pkgs, ... }:
{
  stylix.targets.ghostty.enable = true;

  programs.ghostty = {
    # Prefer local installs
    package = pkgs.nil;

    enable = true;
  };
}
