{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles.herdr;
  shell = config.dotfiles.shellPath;
  # maki panes run inside their nono sandbox profile when nono is enabled.
  makiPaneCmd =
    if config.dotfiles.nono.enable then "nono run -p maki --allow-cwd -- maki" else "maki";

  configToml = ''
    # Managed by home-manager (modules/features/ai/herdr). Manual edits are clobbered.
    onboarding = false

    [theme]
    name = "${cfg.theme}"

    [terminal]
    default_shell = "${shell}"
    shell_mode = "auto"

    [update]
    channel = "stable"

    # prefix+alt+m opens a maki session in a temporary pane (closes on exit).
    # Herdr's binary doesn't know maki as an agent, so the pane shows as a plain
    # terminal; for agent-target treatment use `herdr agent start maki -- maki`.
    [[keys.command]]
    key = "prefix+alt+m"
    type = "pane"
    command = "${makiPaneCmd}"
    description = "new maki session"
  '';
in
{
  config = lib.mkIf cfg.enable {
    home.file = {
      ".config/herdr/config.toml" = {
        force = true;
        text = configToml;
      };
    }
    // lib.optionalAttrs config.dotfiles.maki.enable {
      # Teaches maki to drive Herdr (split panes, spawn agents, wait) from inside
      # a HERDR_ENV pane. maki discovers ~/.config/maki/skills/<name>/SKILL.md;
      # loadable via its `skill` tool as "herdr". Refresh from upstream on bumps.
      ".config/maki/skills/herdr/SKILL.md" = {
        force = true;
        source = ./SKILL.md;
      };
    };
  };
}
