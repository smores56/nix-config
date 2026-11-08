{
  lib,
  pkgs,
  inputs,
}:
let
  inherit (inputs)
    uv2nix
    pyproject-nix
    pyproject-build-systems
    ;

  python = pkgs.python312;

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

  overlay = workspace.mkPyprojectOverlay {
    # The nanobot wheel ships the built WebUI; never build the frontend from source here.
    sourcePreference = "wheel";
  };

  pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.wheel
      overlay
    ]
  );

  virtualenv = pythonSet.mkVirtualEnv "nanobot-env" workspace.deps.default;
in
virtualenv
