# Local photo-triage scorer; the service runs this from the store path.
{
  pkgs,
  lib ? pkgs.lib,
}:
pkgs.python3Packages.buildPythonApplication {
  pname = "photo-triage";
  version = (lib.importTOML ./pyproject.toml).project.version;
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
    ];
  };

  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = false;
  pythonImportsCheck = [ "photo_triage" ];

  meta = {
    description = "Local photo triage for Immich";
    mainProgram = "photo-triage";
  };
}
