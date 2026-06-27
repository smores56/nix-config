{
  config,
  ...
}:
let
  cfg = config.dotfiles.herdr;
  shell = config.dotfiles.shellPath;
  # maki panes run inside their nono sandbox profile
  makiPaneCmd = "nono run -s -- maki";

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
  config = {
    home.file = {
      ".config/herdr/config.toml" = {
        force = true;
        text = configToml;
      };
    };
  };
}
