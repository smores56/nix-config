{
  config,
  lib,
  ...
}:
let
  # Only directories that are actually skills (contain SKILL.md) deploy —
  # stray dirs (__pycache__, editor droppings) would ship as broken skills.
  sharedSkillNames =
    let
      entries = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.);
      hasSkill = name: builtins.pathExists (./. + "/${name}/SKILL.md");
    in
    builtins.filter hasSkill (lib.attrNames entries);

  # ~/.agents/skills is the shared user-scope location: maki and codex both
  # scan it. Claude Code reads ~/.claude/skills (work profile only).
  sharedSkillTargets =
    map (skillName: ".agents/skills/${skillName}") sharedSkillNames
    ++ lib.optionals config.dotfiles.work.enable (
      map (skillName: ".claude/skills/${skillName}") sharedSkillNames
    );
  sharedSkillFiles = lib.genAttrs sharedSkillTargets (target: {
    force = true;
    source = ./${baseNameOf target};
  });
in
{
  config.home.file = sharedSkillFiles;
}
