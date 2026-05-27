{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) piWeb;
  piWebEnabled = piWeb.enable;
  piWebBin = "${config.home.homeDirectory}/.cache/.bun/bin/pi-web";
in
{
  systemd.user.services.pi-web = lib.mkIf (piWebEnabled && pkgs.stdenv.isLinux) {
    Unit = {
      Description = "Pi Web UI for oh-my-pi";
      After = [ "network.target" ];
    };
    Service = {
      Environment = [
        "PATH=${config.home.homeDirectory}/.bun/bin:${config.home.homeDirectory}/.cache/.bun/bin:${config.home.homeDirectory}/.local/bin:/run/wrappers/bin:/home/smores/.nix-profile/bin:/nix/profile/bin:/etc/profiles/per-user/smores/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
      ];
      ExecStartPre = pkgs.writeShellScript "pi-web-patch-agent-cmd" ''
        SERVER_JS="${config.home.homeDirectory}/.cache/.bun/install/cache/pi-web@0.14.0@@@1/build/server/server.js"
        if [ -f "$SERVER_JS" ]; then
          ${pkgs.gnused}/bin/sed -i -e 's|{ command: .npx., args: \[.-y., .@earendil-works/pi-coding-agent@latest.\] }|{ command: "${config.home.homeDirectory}/.cache/.bun/bin/omp", args: [] }|' -e 's|{ command: .npx., args: \[.-y., .@oh-my-pi/pi-coding-agent@latest.\] }|{ command: "${config.home.homeDirectory}/.cache/.bun/bin/omp", args: [] }|' "$SERVER_JS"
        fi
      '';
      ExecStart = "${piWebBin} --agent omp --host ${piWeb.bindAddress} --port ${toString piWeb.port}";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
