# Plain-text todos: one todo.txt in ~/.local/share/todo, managed with tuxedo.
# The data lives under XDG_DATA_HOME; the vault Syncthing daemon on both
# NixOS hosts carries the store and an always-on bindfs mounts it. See
# docs/manual-steps.md ("todo.txt").
{
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

  # `t` is Zellij; td edits the vault-owned store as `vault` itself. The sudo
  # path is absolute so a `sudo` planted earlier on PATH never runs, and
  # `-H` keeps tuxedo's config and cache in vault's own home
  # (docs/kanbei-split.md).
  user.shellAbbrs = {
    td = "/run/wrappers/bin/sudo -H -u vault ${pkgs.tuxedo}/bin/tuxedo /var/lib/data/todo/todo.txt";
  };
}
