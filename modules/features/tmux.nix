{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  base16 = import ../lib/base16.nix { inherit lib; };

  darkColors = base16.parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.darkTheme.system}.yaml";
  lightColors = base16.parseScheme "${pkgs.base16-schemes}/share/themes/${cfg.lightTheme.system}.yaml";

  # Palette-only config, sourced at startup and re-sourced live by the theme
  # switcher in theme.nix (tmux options are server-wide, one call suffices).
  paletteConf =
    colors:
    let
      c = lib.mapAttrs (_: v: "#${v}") colors;
    in
    ''
      set -g status-style "bg=${c.base01},fg=${c.base05}"
      set -g status-left-style "bg=${c.base0E},fg=${c.base01},bold"
      set -g status-right-style "bg=${c.base01},fg=${c.base04}"
      setw -g window-status-style "bg=${c.base01},fg=${c.base04}"
      setw -g window-status-current-style "bg=${c.base04},fg=${c.base00},bold"
      setw -g window-status-activity-style "bg=${c.base01},fg=${c.base09}"
      set -g pane-border-style "fg=${c.base02}"
      set -g pane-active-border-style "fg=${c.base0E}"
      set -g message-style "bg=${c.base01},fg=${c.base05}"
      set -g message-command-style "bg=${c.base01},fg=${c.base0A}"
      set -g mode-style "bg=${c.base02},fg=${c.base05}"
      set -g copy-mode-match-style "bg=${c.base0A},fg=${c.base00}"
      set -g copy-mode-current-match-style "bg=${c.base09},fg=${c.base00}"
      set -g clock-mode-colour "${c.base0E}"
      set -g display-panes-colour "${c.base04}"
      set -g display-panes-active-colour "${c.base0E}"
    '';

  baseIsDark = cfg.polarity != "light";

  clipboardCmd = if pkgs.stdenv.isDarwin then "pbcopy" else "${pkgs.wl-clipboard}/bin/wl-copy";
in
{
  xdg.configFile = {
    "tmux/theme-dark.conf".text = paletteConf darkColors;
    "tmux/theme-light.conf".text = paletteConf lightColors;
  };

  programs.tmux = {
    enable = true;
    # Prefix: Ctrl+N - on Hands Down Neu w/ home-row mods this is hold-E (right
    # ctrl) + tap-N: cross-hand, both middle fingers on home row. Costs pi's
    # cursorDown *alias* (arrows remain) - double-tap C-n to pass through.
    prefix = "C-n";
    keyMode = "emacs"; # arrow-friendly; no hjkl (not a QWERTY layout)
    mouse = true;
    baseIndex = 1;
    escapeTime = 0;
    historyLimit = 50000;
    terminal = "tmux-256color";
    focusEvents = true;
    aggressiveResize = true;
    sensibleOnTop = false;
    extraConfig = ''
      # ── Terminal capabilities ─────────────────────────────────────────
      set -as terminal-features ",*:RGB"
      set -g allow-passthrough on
      set -s extended-keys on
      set -s extended-keys-format csi-u
      set -g renumber-windows on
      set -g detach-on-destroy off
      set -g set-titles on
      set -g set-titles-string "#S: #W"

      # ── Clipboard: OSC52 (works in Ghostty, incl. over ssh) + native cmd ──
      set -s set-clipboard on
      set -s copy-command "${clipboardCmd}"

      # Mouse: drag selects + copies on release (system clipboard via
      # copy-command/OSC52), double-click selects word, triple-click line,
      # middle-click pastes. Wheel scrolls / enters copy-mode automatically.
      bind -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel
      bind -T copy-mode DoubleClick1Pane send -X select-word \; run -d 0.2 \; send -X copy-pipe-and-cancel
      bind -T copy-mode TripleClick1Pane send -X select-line \; run -d 0.2 \; send -X copy-pipe-and-cancel
      bind -n DoubleClick1Pane copy-mode -M \; send -X select-word \; run -d 0.2 \; send -X copy-pipe-and-cancel
      bind -n TripleClick1Pane copy-mode -M \; send -X select-line \; run -d 0.2 \; send -X copy-pipe-and-cancel
      bind -n MouseDown2Pane paste-buffer -p

      # ── Status bar ────────────────────────────────────────────────────
      set -g status-position bottom
      set -g status-left " #S "
      set -g status-right " #h "
      setw -g automatic-rename on
      setw -g automatic-rename-format "#{b:pane_current_path}"
      setw -g window-status-format " #I #W "
      setw -g window-status-current-format " #I #W "

      # ── Theme (palette re-sourced live by the theme switcher) ─────────
      source-file ~/.config/tmux/theme-${if baseIsDark then "dark" else "light"}.conf

      # ── Direct chords (Ctrl+Alt, mirroring the old zellij setup) ──────
      # Split in the larger direction, keeping cwd
      bind -n C-M-n if -F "#{e|>:#{pane_width},#{e|*:2,#{pane_height}}}" \
        'split-window -h -c "#{pane_current_path}"' \
        'split-window -v -c "#{pane_current_path}"'
      # Focus move; at left/right edge, hop windows (zellij MoveFocusOrTab)
      bind -n C-M-Left  if -F "#{pane_at_left}"  "previous-window" "select-pane -L"
      bind -n C-M-Right if -F "#{pane_at_right}" "next-window"     "select-pane -R"
      bind -n C-M-Up    select-pane -U
      bind -n C-M-Down  select-pane -D
      # Move window left/right in the bar
      bind -n C-M-i swap-window -d -t -1
      bind -n C-M-o swap-window -d -t +1
      # Zoom (closest analog to zellij floating toggle)
      bind -n C-M-f resize-pane -Z
      # New window
      bind -n C-M-t new-window -c "#{pane_current_path}"

      # ── Prefix keys (arrow-centric) ────────────────────────────────────
      # Double-tap prefix to send a literal C-n to the program (pi etc.)
      bind C-n send-prefix
      bind Left  select-pane -L
      bind Right select-pane -R
      bind Up    select-pane -U
      bind Down  select-pane -D
      bind -r S-Left  resize-pane -L 3
      bind -r S-Right resize-pane -R 3
      bind -r S-Up    resize-pane -U 3
      bind -r S-Down  resize-pane -D 3
      bind c new-window -c "#{pane_current_path}"
      bind Enter split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"
      bind x kill-pane
      bind Space copy-mode
    '';
  };
}
