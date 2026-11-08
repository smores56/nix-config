# Skill dirs are the ones holding a SKILL.md; stray dirs (__pycache__, editor
# droppings) would ship as broken skills. The home install and the agent VM's
# nanobot workspace share this list.
dir:
let
  entries = builtins.readDir dir;
in
builtins.filter (
  name: entries.${name} == "directory" && builtins.pathExists (dir + "/${name}/SKILL.md")
) (builtins.attrNames entries)
