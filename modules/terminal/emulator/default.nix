{ ... }:
{
  imports = [
    ./kitty.nix
    ./wezterm.nix
    ./alacritty.nix
    ./ghostty.nix
  ];

  home.sessionVariables = {
    TERMINAL = "ghostty";
  };
}
