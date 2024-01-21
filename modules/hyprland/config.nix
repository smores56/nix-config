{ pkgs, ... }: ''
  # See https://wiki.hyprland.org/Configuring/Keywords/ for more

  # See https://wiki.hyprland.org/Configuring/Monitors/
  monitor=,highres,auto,1

  # Execute your favorite apps at launch
  exec-once = waybar & hyprpaper & swayidle timeout 10 "pgrep swaylock && hyprctl dispatch dpms off" resume "hyprctl dispatch dpms on" before-sleep "swaylock"

  # Some default env vars.
  env = XCURSOR_SIZE,24

  windowrulev2=opacity 0.9 0.8,class:^(Alacritty)$,class:^(org.wezfurlong.wezterm)$

  input {
      kb_layout = us
      follow_mouse = 1

      touchpad {
          natural_scroll = no
      }

      sensitivity = 0 # -1.0 - 1.0, 0 means no modification.
  }

  general {
      gaps_in = 5
      gaps_out = 20
      border_size = 2
      col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
      col.inactive_border = rgba(595959aa)

      layout = dwindle
  }

  decoration {
      rounding = 10
      blur {
          enabled = yes
          size = 3
          passes = 1
          new_optimizations = on
      }

      drop_shadow = yes
      shadow_range = 4
      shadow_render_power = 3
      col.shadow = rgba(1a1a1aee)
  }

  animations {
      enabled = yes

      # Some default animations, see https://wiki.hyprland.org/Configuring/Animations/ for more

      bezier = myBezier, 0.05, 0.9, 0.1, 1.05

      animation = windows, 1, 7, myBezier
      animation = windowsOut, 1, 7, default, popin 80%
      animation = border, 1, 10, default
      animation = borderangle, 1, 8, default
      animation = fade, 1, 7, default
      animation = workspaces, 1, 6, default
  }

  dwindle {
      # See https://wiki.hyprland.org/Configuring/Dwindle-Layout/ for more
      pseudotile = yes # master switch for pseudotiling. Enabling is bound to mod + P in the keybinds section below
      preserve_split = yes # you probably want this
  }

  master {
      # See https://wiki.hyprland.org/Configuring/Master-Layout/ for more
      new_is_master = true
  }

  gestures {
      # See https://wiki.hyprland.org/Configuring/Variables/ for more
      workspace_swipe = on
  }

  misc {
      disable_hyprland_logo = true
  }

  $mod = SUPER

  # Example binds, see https://wiki.hyprland.org/Configuring/Binds/ for more
  bind = $mod, Return, exec, kitty
  bind = $mod, B, exec, firefox
  bind = , Print, exec, grimblast copy area
  bind = $mod, Q, killactive,
  bind = $mod, N, exec, thunar
  bind = $mod, L, exec, swaylock
  bind = $mod, D, exec, fuzzel
  bind = $mod, slash, exec, fuzzel
  bind = $mod, V, togglefloating,
  bind = $mod, P, pseudo, # dwindle
  bind = $mod, J, togglesplit, # dwindle

  # Move focus with mod + arrow keys
  bind = $mod, left, movefocus, l
  bind = $mod, right, movefocus, r
  bind = $mod, up, movefocus, u
  bind = $mod, down, movefocus, d

  # Scroll through existing workspaces with mod + scroll
  bind = $mod, mouse_down, workspace, e+1
  bind = $mod, mouse_up, workspace, e-1

  # Move/resize windows with mod + LMB/RMB and dragging
  bindm = $mod, mouse:272, movewindow
  bindm = $mod, mouse:273, resizewindow

  # Resize submap
  bind = $mod, R, submap, resize
  submap = resize
  binde = , right, resizeactive, 10 0
  binde = , left, resizeactive, -10 0
  binde = , up, resizeactive, 0 -10
  binde = , down, resizeactive, 0 10
  # use reset to go back to the global submap
  bind = , escape, submap, reset
  submap = reset

  # Exit submap
  bind = $mod, E, submap, exit
  submap = exit
  binde = , S, exec, systemctl suspend
  binde = , P, exec, systemctl poweroff
  binde = , R, exec, systemctl reboot
  binde = , L, exit,
  # use reset to go back to the global submap
  bind = , escape, submap, reset
  submap = reset

  bindle=, XF86MonBrightnessUp, exec, brightnessctl set 5%+
  bindle=, XF86MonBrightnessDown, exec, brightnessctl set 5%-
  bindle=, XF86AudioRaiseVolume, exec, pactl -- set-sink-volume @DEFAULT_SINK@ +5%
  bindle=, XF86AudioLowerVolume, exec, pactl -- set-sink-volume @DEFAULT_SINK@ -5%
  bindl=, XF86AudioMute, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle
  bindl=, XF86AudioPlay, exec, playerctl play-pause
  bindl=, XF86AudioNext, exec, playerctl next
  bindl=, XF86AudioPrev, exec, playerctl previous

  # workspaces
  # binds $mod + [shift +] {1..10} to [move to] workspace {1..10}
  ${builtins.concatStringsSep "\n" (builtins.genList (
      x: let
        ws = let
          c = (x + 1) / 10;
        in
          builtins.toString (x + 1 - (c * 10));
      in ''
        bind = $mod, ${ws}, workspace, ${toString (x + 1)}
        bind = $mod SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}
      ''
    )
    10)}
''
