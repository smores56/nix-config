# The work Mac's scheduled harvest: commits in work-owner repos, GitHub PRs and Jira tickets
# become episodes in the local memory instance (see harvest.py). Chat and mail are never harvested.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;
  home = config.home.homeDirectory;
  stateDir = "${home}/.local/state/harvest";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./harvest.py;
  };
  # Checkouts whose reflogs the harvest reads: codeRoot plus the work host's flat folder.
  repoRoots = [
    cfg.codeRoot
    cfg.work.flatRepos.dir
  ];
  # launchd starts jobs with a bare PATH. gh and git come from Nix; acli is a Homebrew install.
  runPath = lib.concatStringsSep ":" [
    "${pkgs.git}/bin"
    "${pkgs.gh}/bin"
    "/opt/homebrew/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];
  harvest = pkgs.writeShellScriptBin "harvest" ''
    export PATH=${runPath}
    export HARVEST_STATE_DIR=${lib.escapeShellArg stateDir}
    export HARVEST_REPO_ROOTS=${lib.escapeShellArg (lib.concatStringsSep ":" repoRoots)}
    export HARVEST_USER=${lib.escapeShellArg config.machine.username}
    export HARVEST_MEMORY=${config.home.profileDirectory}/bin/memory
    export HARVEST_WORK_OWNERS=${lib.escapeShellArg (lib.concatStringsSep "," cfg.work.githubOwners)}
    exec ${pkgs.python3}/bin/python3 ${src}/harvest.py "$@"
  '';
in
{
  config = lib.mkIf config.machine.workHost {
    home.packages = [ harvest ];

    # Weekdays at 17:30; launchd runs a missed interval on wake, and the harvest waits for the
    # network first.
    launchd.agents.harvest = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      enable = true;
      config = {
        ProgramArguments = [
          "${harvest}/bin/harvest"
          "run"
        ];
        EnvironmentVariables.HOME = home;
        StartCalendarInterval = map (weekday: {
          Weekday = weekday;
          Hour = 17;
          Minute = 30;
        }) (lib.range 1 5);
        StandardOutPath = "${home}/Library/Logs/harvest.log";
        StandardErrorPath = "${home}/Library/Logs/harvest.log";
        ProcessType = "Background";
      };
    };
  };
}
