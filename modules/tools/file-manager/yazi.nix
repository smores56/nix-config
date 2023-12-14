{ pkgs, lightTheme, ... }: {
  home.packages = [ pkgs.yazi ];

  home.file.".config/bat/themes/gruvbox-dark.tmTheme".source = ./gruvbox-dark.tmTheme;
  home.file.".config/bat/themes/gruvbox-light.tmTheme".source = ./gruvbox-light.tmTheme;

  home.file.".config/yazi/theme.toml".text = ''
    [manager]
    syntect_theme = "~/.config/bat/themes/gruvbox-${if lightTheme then "light" else "dark"}.tmTheme"
  '';
}
