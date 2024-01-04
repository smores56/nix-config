{ pkgs, ... }: {
  home.packages = [ pkgs.yazi ];

  home.file.".config/bat/themes/gruvbox-dark.tmTheme".source = ./gruvbox-dark.tmTheme;

  home.file.".config/yazi/theme.toml".text = ''
    [manager]
    syntect_theme = "~/.config/bat/themes/gruvbox-dark.tmTheme"
  '';
}
