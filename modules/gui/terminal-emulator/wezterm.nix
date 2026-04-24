{ pkgs, ... }:
{
  stylix.targets.wezterm.enable = true;

  programs.wezterm = {
    # Prefer local installs
    package = pkgs.nil;

    enable = true;
    extraConfig = ''
      return {
        enable_wayland = false,
        hide_tab_bar_if_only_one_tab = true,
        hide_mouse_cursor_when_typing = false,
        hide_tab_bar_if_only_one_tab = true,
        send_composed_key_when_left_alt_is_pressed = false,
        send_composed_key_when_right_alt_is_pressed = false,
        audible_bell = "Disabled",
        visual_bell = {
          fade_in_function = "EaseIn",
          fade_in_duration_ms = 150,
          fade_out_function = "EaseOut",
          fade_out_duration_ms = 150,
        },
        colors = {
          visual_bell = "#202020",
        },
        initial_cols = 200,
        initial_rows = 50,
        default_prog = { "${pkgs.fish}/bin/fish" },
      }
    '';
  };
}
