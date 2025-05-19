{ pkgs, ... }:
{
  home.packages = [ pkgs.yazi ];

  xdg.configFile."yazi/yazi.toml".text = ''
    "$schema" = "https://yazi-rs.github.io/schemas/yazi.json"

    [manager]
    ratio          = [ 1, 4, 3 ]
    sort_by        = "natural"
    sort_sensitive = false
    sort_reverse   = false
    sort_dir_first = true
    linemode       = "none"
    show_hidden    = false
    show_symlink   = true
  '';
}
