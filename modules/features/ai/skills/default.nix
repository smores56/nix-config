{
  config,
  lib,
  pkgs,
  ...
}:
let
  mirror = import ../../../lib/agent-skill-mirror.nix { inherit pkgs; };

  # Only directories that are actually skills (contain SKILL.md) deploy —
  # stray dirs (__pycache__, editor droppings) would ship as broken skills.
  sharedSkillNames =
    let
      entries = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.);
      hasSkill = name: builtins.pathExists (./. + "/${name}/SKILL.md");
    in
    builtins.filter hasSkill (lib.attrNames entries);

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
  config = {
    home.file = sharedSkillFiles;
    # Skills other tools install into ~/.claude/skills reach maki and codex
    # too; rerun `agent-skill-mirror` by hand after such an install.
    home.activation.agentSkillMirror = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe mirror} ${
        lib.escapeShellArgs [
          "${config.home.homeDirectory}/.claude/skills"
          "${config.home.homeDirectory}/.agents/skills"
        ]
      }
    '';
    home.packages = [ mirror ];
  };
}
