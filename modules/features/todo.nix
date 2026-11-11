# Plain-text todos: one todo.txt in the vault-owned store, managed with tuxedo.
# The store is a size-capped filesystem mounted at /var/lib/data/todo and synced
# by the vault Syncthing daemon (modules/nixos/todo-daemon.nix). See
# docs/manual-steps.md ("todo.txt").
{
  pkgs,
  ...
}:
{
  home.packages = [ pkgs.tuxedo ];

  # tuxedo rewrites this file when a setting changes in the TUI; force replaces
  # the resulting regular file on the next switch. This config is for files the
  # human owns; `td` uses the vault user's own copy.
  xdg.configFile."tuxedo/config.toml" = {
    force = true;
    text = ''
      theme = Terminal
    '';
  };

  # `t` is Zellij. `td` edits the vault-owned store as `vault` through
  # `todo-open`, which refuses an unmounted tree or a symlinked todo.txt. Both
  # paths are absolute: sudo resets PATH, and a `sudo` planted earlier on PATH
  # must never receive the YubiKey touch.
  user.shellAbbrs = {
    td = "/run/wrappers/bin/sudo -u vault /run/current-system/sw/bin/todo-open";
  };
}
