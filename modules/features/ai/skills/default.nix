{
  config,
  lib,
  ...
}:
let
  sharedSkillNames = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.)
  );
  sharedSkillTargets =
    lib.flatten (
      map (skillName: [
        ".config/maki/skills/${skillName}"
        ".omp/agent/skills/${skillName}"
      ]) sharedSkillNames
    )
    ++ lib.optionals config.dotfiles.work.enable (
      lib.flatten (
        map (skillName: [
          ".claude/skills/${skillName}"
          ".codex/skills/${skillName}"
        ]) sharedSkillNames
      )
    );
  sharedSkillFiles = lib.genAttrs sharedSkillTargets (target: {
    force = true;
    source = ./${baseNameOf target};
  });
in
{
  config.home.file = sharedSkillFiles;
}
