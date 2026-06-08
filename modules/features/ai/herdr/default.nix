{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.herdr;
  enabled = cfg.enable && pkgs.stdenv.isLinux;
  homeDir = config.home.homeDirectory;
  scriptPath =
    "${homeDir}/.local/bin:${homeDir}/.nix-profile/bin:${homeDir}/.local/state/nix/profile/bin:"
    + "/etc/profiles/per-user/${config.dotfiles.username}/bin:"
    + "/run/current-system/sw/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin";
in
{
  config = lib.mkIf enabled {
    home.packages = [ pkgs.ttyd ];

    home.file.".config/herdr/config.toml" = {
      text = ''
        onboarding = false

        [keys]
        previous_workspace = "ctrl+alt+left"
        next_workspace = "ctrl+alt+right"
        previous_agent = "ctrl+alt+up"
        next_agent = "ctrl+alt+down"

        [[keys.command]]
        key = "prefix+O"
        type = "pane"
        command = "omp"
        description = "new omp agent tab"
      '';
      force = true;
    };

    systemd.user.services.herdr-ttyd = {
      Unit = {
        Description = "Herdr web terminal (ttyd + herdr session attach default)";
        After = [ "network.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.ttyd}/bin/ttyd --writable --port ${toString cfg.port} herdr session attach default";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [ "PATH=${scriptPath}" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
