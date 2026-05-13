{ lib }:
{
  parseScheme =
    file:
    let
      content = builtins.readFile file;
      lines = lib.splitString "\n" content;
      parseLine =
        line:
        let
          match = builtins.match ''[[:space:]]+(base[0-9A-Fa-f]+):[[:space:]]+"#([0-9a-fA-F]+)".*'' line;
        in
        if match != null then
          {
            name = builtins.elemAt match 0;
            value = builtins.elemAt match 1;
          }
        else
          null;
      parsed = builtins.filter (x: x != null) (map parseLine lines);
      result = builtins.listToAttrs parsed;
    in
    assert
      builtins.length parsed >= 16
      || throw "parseScheme: expected at least 16 base16 colors in ${file}, got ${toString (builtins.length parsed)}";
    result;
}
