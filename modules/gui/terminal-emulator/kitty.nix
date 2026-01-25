{ pkgs, ... }:
{
  stylix.targets.kitty.enable = true;

  programs.kitty = {
    # Prefer local installs
    package = pkgs.nil;

    enable = true;
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
