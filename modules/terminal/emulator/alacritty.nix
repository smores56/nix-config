{ pkgs, ... }: {
  programs.alacritty = {
    enable = true;
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
