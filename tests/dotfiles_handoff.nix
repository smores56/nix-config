# smoreswork with every piece in user.dotfilesOwns still evaluates, and home-manager stops writing the files each
# piece owns. `files` is the source of truth for what a piece owns, relative to $HOME; the baseline half proves
# every entry is written while nothing is handed over, so a renamed file cannot hide from the other half.
{
  lib,
  all,
  base,
  handed,
}:
let
  files = {
    zsh = [
      ".zshenv"
      ".config/zsh/.zshenv"
      ".config/zsh/.zprofile"
      ".config/zsh/.zshrc"
    ];
    helix = [
      ".config/helix/config.toml"
      ".config/helix/languages.toml"
      ".config/helix/themes/stylix.toml"
    ];
    zellij = [
      ".config/zellij/config.kdl"
      ".config/zellij/themes/stylix.kdl"
    ];
    yazi = [
      ".config/yazi/yazi.toml"
      ".config/yazi/theme.toml"
    ];
    lazygit = [ "Library/Application Support/lazygit/config.yml" ];
    television = [
      ".config/television/cable/repos.toml"
      ".config/television/cable/worktrees.toml"
    ];
    gh = [ ".config/gh/config.yml" ];
    aerospace = [ ".aerospace.toml" ];
  };

  # xdg.configFile entries land in home.file under absolute keys.
  written =
    c:
    map (lib.removePrefix "${c.home.homeDirectory}/") (
      lib.attrNames (lib.filterAttrs (_: f: f.enable) c.home.file)
    );

  baseline = written base.config;
  after = written handed.config;
  owned = lib.concatMap (piece: files.${piece}) all;

  missingFromBaseline = lib.filter (f: !(lib.elem f baseline)) owned;
  stillWritten = lib.filter (f: lib.elem f after) owned;
  untabled = lib.filter (piece: !(files ? ${piece})) all;
in
assert lib.assertMsg (
  untabled == [ ]
) "tests/dotfiles_handoff.nix has no file list for: ${toString untabled}";
assert lib.assertMsg (
  builtins.length (builtins.attrNames files) == builtins.length all
) "tests/dotfiles_handoff.nix lists pieces the option does not have";
assert lib.assertMsg (
  missingFromBaseline == [ ]
) "listed files home-manager does not write at baseline: ${toString missingFromBaseline}";
assert lib.assertMsg (
  stillWritten == [ ]
) "files still written with their piece handed over: ${toString stillWritten}";
builtins.seq handed.activationPackage.drvPath "ok"
