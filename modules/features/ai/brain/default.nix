{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.dotfiles.brain) dir;
  # One store dir so brain-commit can load the digest's shared secret patterns.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "py") ./.;
  };
  # PATH bins so the brain skill can call them by name from any session.
  mkBin =
    name:
    pkgs.writeShellScriptBin name ''
      export PATH=${pkgs.git}/bin:$PATH
      exec ${pkgs.python3}/bin/python3 ${src}/${name}.py "$@"
    '';
in
{
  config = {
    home.packages = [
      (mkBin "brain-digest")
      (mkBin "brain-commit")
    ];
    # The brain skill and brain-commit both resolve the vault from this.
    home.sessionVariables = lib.optionalAttrs (dir != null) {
      BRAIN_DIR = "${config.home.homeDirectory}/${dir}";
    };
  };
}
