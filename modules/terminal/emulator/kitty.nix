{ pkgs, ... }: {
  programs.kitty = {
    enable = true;
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
