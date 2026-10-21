# The memory wrapper, Maki's stdio shim, and the `memory` CLI. One derivation
# with three console scripts so the server, the client shim, and the CLI can
# never drift apart.
{
  pkgs,
  lib ? pkgs.lib,
}:
pkgs.python3Packages.buildPythonApplication {
  pname = "memory-mcp";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
    ];
  };

  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = [ pkgs.python3Packages.mcp ];

  # Group derivation shells out to git. The wrappers prepend it to PATH so the
  # systemd unit and the home package behave the same without relying on the
  # caller's PATH.
  nativeBuildInputs = [ pkgs.makeWrapper ];
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ pkgs.git ])
  ];

  doCheck = false;
  pythonImportsCheck = [ "memory_mcp" ];

  meta = {
    description = "Cross-machine memory MCP wrapper, shim, and CLI";
    mainProgram = "memory";
  };
}
