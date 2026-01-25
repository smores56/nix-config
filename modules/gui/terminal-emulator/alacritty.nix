{ pkgs, ... }:
{
  stylix.targets.alacritty.enable = true;

  programs.alacritty = {
    # Prefer local installs
    package = pkgs.nil;

    enable = true;
    settings = {
      terminal.shell = "${pkgs.fish}/bin/fish";

      window = {
        decorations = "Buttonless";
        option_as_alt = "Both";
        blur = true;
      };
    };
  };
}
