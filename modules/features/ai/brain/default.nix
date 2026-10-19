{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;
  inherit (cfg.brain) dir;
  home = config.home.homeDirectory;
  vault = "${home}/${dir}";
  stateDir = "${home}/.local/state/brain";
  # One store dir so the tools can load each other's shared patterns.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "py") ./.;
  };
  # Checkouts whose reflogs the harvest reads: codeRoot plus a work host's flat folder.
  repoRoots = [
    cfg.codeRoot
  ]
  ++ lib.optional (config.machine.workHost && cfg.work.flatRepos != null) cfg.work.flatRepos.dir;
  # launchd starts jobs with a bare PATH. claude is installed outside Nix, so it is
  # named by full path rather than letting ~/.local/bin shadow system tools.
  runPath = lib.concatStringsSep ":" [
    "${pkgs.git}/bin"
    "${pkgs.gh}/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];
  # PATH bins so the brain skill can call them by name from any session. Defaults
  # are baked in rather than read from the shell, since launchd has no shell env.
  mkBin =
    name: env:
    pkgs.writeShellScriptBin name ''
      export PATH=${pkgs.git}/bin:$PATH
      ${lib.concatStrings (lib.mapAttrsToList (k: v: ": \"\${${k}:=${v}}\"; export ${k}\n") env)}
      exec ${pkgs.python3}/bin/python3 ${src}/${name}.py "$@"
    '';
  runEnv = {
    BRAIN_DIR = vault;
    BRAIN_STATE_DIR = stateDir;
    BRAIN_REPO_ROOTS = lib.concatStringsSep ":" repoRoots;
    BRAIN_SKILL = "${../skills/brain/SKILL.md}";
    BRAIN_CLAUDE = "${home}/.local/bin/claude";
  };
  brainRun = mkBin "brain-run" runEnv;
in
{
  config = {
    home.packages = [
      (mkBin "brain-digest" { })
      (mkBin "brain-commit" { })
    ]
    ++ lib.optional (dir != null) brainRun;
    # The brain skill and brain-commit both resolve the vault from this.
    home.sessionVariables = lib.optionalAttrs (dir != null) {
      BRAIN_DIR = vault;
    };

    # Weekdays at 17:30, harvest and draft the next standup; launchd runs a
    # missed interval on wake, and brain-run waits for the network first.
    launchd.agents.brain-autopilot = lib.mkIf (dir != null && pkgs.stdenv.hostPlatform.isDarwin) {
      enable = true;
      config = {
        ProgramArguments = [
          "${brainRun}/bin/brain-run"
          "run"
        ];
        EnvironmentVariables = {
          PATH = runPath;
          HOME = home;
        };
        StartCalendarInterval = map (weekday: {
          Weekday = weekday;
          Hour = 17;
          Minute = 30;
        }) (lib.range 1 5);
        StandardOutPath = "${home}/Library/Logs/brain-autopilot.log";
        StandardErrorPath = "${home}/Library/Logs/brain-autopilot.log";
        ProcessType = "Background";
      };
    };
  };
}
