{ pkgs, ... }: {
  stylix.targets.alacritty.enable = true;

  programs.alacritty = {
    enable = true;
    settings = {
      shell = "${pkgs.fish}/bin/fish";
      window = {
        decorations = "None";
        blur = true;
      };
    };
  };
}
