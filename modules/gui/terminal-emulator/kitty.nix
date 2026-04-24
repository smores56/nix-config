{ pkgs, ... }:
{
  programs.kitty = {
    # Prefer local installs
    package = pkgs.nil;

    enable = true;
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
