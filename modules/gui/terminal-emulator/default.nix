{ ... }:
{
  fonts.fontconfig.enable = true;

  imports = [
    ./kitty.nix
    ./wezterm.nix
    ./alacritty.nix
    ./ghostty.nix
  ];

  home.sessionVariables = {
    TERMINAL = "wezterm";
  };
}
