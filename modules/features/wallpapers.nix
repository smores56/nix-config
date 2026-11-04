# Wallpapers from the durable tree on smortress: rsync one collection into a local cache, bucket
# images by measured aspect, set one per display. The client owns the cache so an unreachable
# source cannot blank the current wallpaper.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  source = "smortress:/var/lib/data/wallpapers/";
  cacheDir = "${config.home.homeDirectory}/.cache/wallpapers";
  intervalHours = 3;

  # Body in a shell file so editors see shell; the wrapper adds errexit/nounset/pipefail and a pinned PATH.
  script =
    builtins.replaceStrings
      [ "@PLATFORM@" "@SOURCE@" "@CACHE@" ]
      [
        (if isLinux then "linux" else "darwin")
        (lib.escapeShellArg source)
        (lib.escapeShellArg cacheDir)
      ]
      (builtins.readFile ./wallpapers.sh);

  wallpapers = pkgs.writeShellApplication {
    name = "wallpapers";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.jq
      pkgs.openssh
      pkgs.rsync
    ]
    ++ lib.optionals isLinux [
      pkgs.imagemagick
      pkgs.util-linux
      # The session's binaries, not the user manager PATH; niri also pins the IPC version the script speaks.
      config.programs.niri.package
      config.programs.noctalia.package
    ]
    ++ lib.optionals (!isLinux) [ pkgs.desktoppr ];
    text = script;
  };
in
{
  home.packages = [ wallpapers ];

  # niri-session imports WAYLAND_DISPLAY and NIRI_SOCKET into the user manager.
  systemd.user.services.wallpapers = lib.mkIf isLinux {
    Unit = {
      Description = "Rotate wallpapers from the durable tree";
      After = [ "graphical-session.target" ];
      # The login start races the compositor/agent: retry rather than lose the run until the three-hour timer.
      StartLimitIntervalSec = 600;
      StartLimitBurst = 10;
    };
    Service = {
      Type = "oneshot";
      TimeoutStartSec = "20min";
      Restart = "on-failure";
      RestartSec = 30;
      # The SSH proxy must not open an unannounced PIN dialog from a timer.
      Environment = [ "YK_ENSURE_NO_PROMPT=1" ];
      ExecStart = "${wallpapers}/bin/wallpapers sync";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.timers.wallpapers = lib.mkIf isLinux {
    Unit.Description = "Rotate wallpapers from the durable tree";
    Timer = {
      # Paces repeats only; OnStartupSec would fire from the lingering user manager at boot, before any compositor.
      OnUnitInactiveSec = "${toString intervalHours}h";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # RunAtLoad plus StartInterval covers login and schedule; launchd runs one missed interval on wake.
  launchd.agents.wallpapers = lib.mkIf (!isLinux) {
    enable = true;
    config = {
      ProgramArguments = [
        "${wallpapers}/bin/wallpapers"
        "sync"
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
        # A cold PIV agent with no cached PIN fails the run, never prompts.
        YK_ENSURE_NO_PROMPT = "1";
      };
      RunAtLoad = true;
      StartInterval = intervalHours * 60 * 60;
      ProcessType = "Background";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/wallpapers.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/wallpapers.log";
    };
  };
}
