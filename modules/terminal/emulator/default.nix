{ ... }: {
  imports = [
    ./kitty.nix
    ./wezterm.nix
    ./alacritty.nix
  ];

  home.sessionVariables = {
    TERMINAL = "kitty";
  };
}
