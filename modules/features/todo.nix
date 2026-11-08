# Plain-text todos: one todo.txt in ~/.local/share/todo, managed with tuxedo.
# The data lives under XDG_DATA_HOME; the vault Syncthing daemon on both
# NixOS hosts carries the store and an always-on bindfs mounts it. See
# docs/manual-steps.md ("todo.txt").
{
  config,
  pkgs,
  ...
}:
{
  home.packages = [ pkgs.tuxedo ];

  # tuxedo rewrites this file when a setting changes in the TUI; force replaces
  # the resulting regular file on the next switch.
  xdg.configFile."tuxedo/config.toml" = {
    force = true;
    text = ''
      theme = Terminal
    '';
  };

  # `t` is Zellij; td keeps the hidden path out of the way.
  user.shellAbbrs = {
    td = "tuxedo ${config.home.homeDirectory}/.local/share/todo/todo.txt";
  };
}
