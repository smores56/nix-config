# Wallpapers from the durable tree on smortress: rsync one curated collection
# into a local cache, bucket each image by its measured aspect, and set one per
# display. The client owns the cache, so an unreachable source cannot blank the
# current wallpaper.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  # The durable tree on smortress is the only source; the sync is one-way and
  # never writes back.
  source = "smortress:/var/lib/data/wallpapers/";
  cacheDir = "${config.home.homeDirectory}/.cache/wallpapers";
  intervalHours = 3;

  # The body lives in a shell file so editors and diffs see it as shell; the
  # wrapper supplies errexit/nounset/pipefail and a pinned PATH.
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
      # The session's binaries, not whatever the user manager PATH happens to
      # hold; niri also pins the IPC version the script speaks to.
      config.programs.niri.package
      config.programs.noctalia.package
    ]
    ++ lib.optionals (!isLinux) [ pkgs.desktoppr ];
    text = script;
  };
in
{
  home.packages = [ wallpapers ];

  # niri-session imports WAYLAND_DISPLAY and NIRI_SOCKET into the user manager,
  # which is how niri and noctalia find their sockets from this unit.
  systemd.user.services.wallpapers = lib.mkIf isLinux {
    Unit = {
      Description = "Rotate wallpapers from the durable tree";
      After = [ "graphical-session.target" ];
      # The login start races the compositor/agent; retry a bounded number of
      # times rather than losing the run until the three-hour timer.
      StartLimitIntervalSec = 600;
      StartLimitBurst = 10;
    };
    Service = {
      Type = "oneshot";
      # A wedged rsync must not pin the timer forever.
      TimeoutStartSec = "20min";
      Restart = "on-failure";
      RestartSec = 30;
      # The SSH proxy must not open an unannounced PIN dialog from a timer.
      Environment = [ "YK_ENSURE_NO_PROMPT=1" ];
      ExecStart = "${wallpapers}/bin/wallpapers sync";
    };
    # The login run: graphical-session.target is started by the session manager.
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.timers.wallpapers = lib.mkIf isLinux {
    Unit.Description = "Rotate wallpapers from the durable tree";
    Timer = {
      # Paces the repeats only; it cannot express "at login" (that is the
      # service's WantedBy above), and OnStartupSec would fire from the
      # lingering user manager at boot, before any compositor exists.
      OnUnitInactiveSec = "${toString intervalHours}h";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # launchd has no timer unit; RunAtLoad plus StartInterval covers login and
  # the schedule, and launchd runs one missed interval on wake.
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
