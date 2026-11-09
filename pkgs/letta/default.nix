# Letta Code (sdlc #495). The PyPI wheel is not a Python library: it is a payload
# carrier holding a bundled Node runtime, the compiled CLI, and prebuilt native
# modules. `letta_code/__init__.py` is a 30-line launcher that execve's
# `_payload/bin/node _payload/app/letta.js`, so the venv exists only to produce
# the `letta` console script and the payload is what actually runs.
#
# The payload's ELF files (node, ripgrep, node-pty, sharp, libvips) are generic
# manylinux builds and refuse to start on NixOS, so autoPatchelfHook rewrites
# them. Their only external dependencies are glibc, libstdc++ and libgcc_s.
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

  # The wheel is the only source; never build the CLI from source here.
  overlay = lib.composeManyExtensions [
    (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
    (final: prev: {
      letta = prev.letta.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.autoPatchelfHook ];
        buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.stdenv.cc.cc.lib ];
      });
    })
  ];

  pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.wheel
      overlay
    ]
  );

  virtualenv = pythonSet.mkVirtualEnv "letta-env" workspace.deps.default;
in
virtualenv
