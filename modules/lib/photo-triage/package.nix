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
  dependencies = [
    pkgs.python3Packages.pillow
    pkgs.python3Packages.numpy
  ];
  doCheck = false;
  pythonImportsCheck = [
    "photo_triage"
    "photo_triage.model"
    "photo_triage.duplicates"
    "photo_triage.decisions"
    "photo_triage.albums"
    "photo_triage.calibration"
  ];

  meta = {
    description = "Local photo triage for Immich";
    mainProgram = "photo-triage";
  };
}
