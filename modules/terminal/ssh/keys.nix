{ lib, ... }: builtins.filter (s: s != "") (lib.strings.splitString "\n" (builtins.readFile ./authorized_keys))
