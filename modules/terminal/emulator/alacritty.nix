{ pkgs, ... }: {
  programs.alacritty = {
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
