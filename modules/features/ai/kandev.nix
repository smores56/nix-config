{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.kandev;
  enabled = cfg.enable && pkgs.stdenv.isLinux;
  homeDir = config.home.homeDirectory;
  port = toString cfg.port;
  dbPath = "${homeDir}/.kandev/data/kandev.db";

  scriptPath = "${homeDir}/.bun/bin:${homeDir}/.cache/.bun/bin:${homeDir}/.opencode/bin:${homeDir}/.local/bin:" + lib.makeBinPath [
    pkgs.nodejs
    pkgs.coreutils
    pkgs.git
  ] + ":${homeDir}/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin";

  kandevStart = pkgs.writeShellScript "kandev-start" ''
    # After Kandev finishes initializing, force auto-approve on all profiles
    # and patch any running session snapshots that still have the old defaults.
    (sleep 10 && ${pkgs.sqlite}/bin/sqlite3 "${dbPath}" "
      UPDATE agent_profiles SET auto_approve = 1, dangerously_skip_permissions = 1 WHERE deleted_at IS NULL;
      UPDATE task_sessions SET agent_profile_snapshot = json_set(
        json_set(agent_profile_snapshot, '\$.auto_approve', json('true')),
        '\$.dangerously_skip_permissions', json('true')
      ) WHERE state NOT IN ('COMPLETED', 'FAILED');
      UPDATE task_sessions SET agent_profile_snapshot = json_set(
        json_set(agent_profile_snapshot, '\$.AutoApprove', json('true')),
        '\$.DangerouslySkipPermissions', json('true')
      ) WHERE state NOT IN ('COMPLETED', 'FAILED');
    ") &

    exec npx kandev@latest run --headless --backend-port ${port}
  '';
in
{
  config = lib.mkIf enabled {
    home.file.".kandev/workspaces/bd9b96d3-670a-4f65-9c48-793ace6383d1/kandev.yml".text = ''
      name: Default Workspace
      permission_handling_mode: auto_approve
    '';

    systemd.user.services.kandev = {
      Unit = {
        Description = "Kandev AI development environment";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "PATH=${scriptPath}"
          "KANDEV_SERVER_HOST=${cfg.bindAddress}"
          "KANDEV_SERVER_PORT=${port}"
          "KANDEV_HOME_DIR=${homeDir}/.kandev"
          "KANDEV_DOCKER_ENABLED=false"
          "KANDEV_FEATURES_OFFICE=true"
          "HOME=${homeDir}"
        ];
        ExecStart = kandevStart;
        WorkingDirectory = homeDir;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
