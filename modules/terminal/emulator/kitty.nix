{ pkgs, ... }: {
  programs.kitty = {
    settings.shell = "${pkgs.fish}/bin/fish";
  };
}
