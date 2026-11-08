# Plain-text todos: one todo.txt in ~/.local/share/todo, managed with todo.sh
# or tuxedo. The data lives under XDG_DATA_HOME; the vault Syncthing daemon on both
# NixOS hosts carries the store and an always-on bindfs mounts it. See
# docs/manual-steps.md ("todo.txt").
{
  config,
  pkgs,
  ...
}:
{
  home.packages = [
    pkgs.todo-txt-cli
    pkgs.tuxedo
  ];

  # todo.sh looks here by default; the package's own config under $out/etc is
  # never consulted.
  xdg.configFile."todo/config".text = ''
    export TODO_DIR="$HOME/.local/share/todo"
    export TODO_FILE="todo.txt"
    export DONE_FILE="done.txt"
    export REPORT_FILE="report.txt"
    export EDITOR="${pkgs.tuxedo}/bin/tuxedo"
  '';

  # tuxedo rewrites this file when a setting changes in the TUI; force replaces
  # the resulting regular file on the next switch.
  xdg.configFile."tuxedo/config.toml" = {
    force = true;
    text = ''
      theme = Terminal
    '';
  };

  # `t` is Zellij; td/te keep the hidden path out of the way.
  user.shellAbbrs = {
    td = "todo.sh";
    te = "tuxedo ${config.home.homeDirectory}/.local/share/todo/todo.txt";
  };
}
