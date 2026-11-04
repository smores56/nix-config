# The `repos` and `worktrees` CLIs (television cables in ../tv call them). Not a
# module: tv imports this for the two packages. Per-host values are substituted
# into the `@NAME@` placeholders of the .sh files.
{
  config,
  lib,
  pkgs,
}:
let
  cfg = config.user;

  workFlatDir = if config.machine.workHost then cfg.work.flatRepos.dir else "";

  # Shared by both tools: host, owner, repo of the cwd's origin.
  originParts = builtins.readFile ./origin-parts.sh;

  script =
    file: vars:
    originParts
    + "\n"
    + builtins.replaceStrings (builtins.attrNames vars) (builtins.attrValues vars) (
      builtins.readFile file
    );
in
{
  repos = pkgs.writeShellApplication {
    name = "repos";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      pkgs.gnused
      pkgs.television
    ];
    text = script ./repos.sh {
      "@CODE_ROOT@" = lib.escapeShellArg cfg.codeRoot;
      "@WORK_FLAT@" = lib.escapeShellArg workFlatDir;
      "@WORK_OWNERS@" = lib.escapeShellArgs cfg.work.githubOwners;
    };
  };

  worktrees = pkgs.writeShellApplication {
    name = "worktrees";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.television
    ];
    text = script ./worktrees.sh {
      "@BRANCH_TEMPLATE@" = lib.escapeShellArg cfg.branchNaming.template;
      "@BRANCH_UNTICKETED@" = lib.escapeShellArg (toString cfg.branchNaming.unticketed);
    };
  };
}
