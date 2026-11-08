{
  lib,
  ...
}:
let
  sharedSkillNames = import ../../../lib/skills.nix ./.;

  # ~/.agents/skills is the shared user-scope location: maki and codex both
  # scan it. Claude Code reads ~/.claude/skills.
  sharedSkillTargets =
    map (skillName: ".agents/skills/${skillName}") sharedSkillNames
    ++ map (skillName: ".claude/skills/${skillName}") sharedSkillNames;
  sharedSkillFiles = lib.genAttrs sharedSkillTargets (target: {
    force = true;
    source = ./${baseNameOf target};
  });
in
{
  config.home.file = sharedSkillFiles;
}
