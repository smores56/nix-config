{ pkgs, ... }: {
  stylix.targets.kitty.enable = true;

  programs.kitty = {
    enable = true;
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
