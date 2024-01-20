{ pkgs, ... }: {
  stylix.targets.wezterm.enable = true;

  programs.wezterm = {
    enable = true;
    extraConfig = ''
      return {
        enable_wayland = false,
        hide_tab_bar_if_only_one_tab = true,
        hide_mouse_cursor_when_typing = false,
        hide_tab_bar_if_only_one_tab = true,
        initial_cols = 200,
        initial_rows = 50,
        default_prog = { "${pkgs.fish}/bin/fish" },
      }
    '';
  };
}
