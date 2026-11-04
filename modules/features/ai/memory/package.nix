# Wrapper, stdio shim, `memory` CLI and LLM proxy in one derivation so they cannot drift apart.
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
  dependencies = with pkgs.python3Packages; [
    anyio
    httpx
    mcp
    redis
    starlette
    uvicorn
  ];

  # Group derivation needs git, file search needs ripgrep; prepend both so
  # the systemd unit and the home package do not depend on the caller's PATH.
  nativeBuildInputs = [ pkgs.makeWrapper ];
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      pkgs.git
      pkgs.ripgrep
    ])
  ];

  doCheck = false;
  pythonImportsCheck = [
    "memory_mcp.wrapper"
    "memory_mcp.shim"
    "memory_mcp.cli"
    "memory_mcp.export"
    "memory_mcp.graph"
    "memory_mcp.registry"
    "memory_mcp.reconciler"
    "memory_mcp.llm_proxy"
    "memory_mcp.mcp_auth"
    "memory_mcp.files"
  ];

  meta = {
    description = "Cross-machine memory MCP wrapper, shim, and CLI";
    mainProgram = "memory";
  };
}
