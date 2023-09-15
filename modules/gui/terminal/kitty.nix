{ pkgs, ... }: {
  programs.kitty = {
    enable = true;

    settings = {
      shell = "${pkgs.fish}/bin/fish";
    };
    font = {
      package = pkgs.cascadia-code;
      name = "CaskaydiaCove Nerd Font";
      size = 12;
    };
  };
}
