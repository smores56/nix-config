# The memory wrapper, Maki's stdio shim, the `memory` CLI, and Graphiti's
# thinkless LLM proxy. One derivation so the server, clients, and proxy can
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
  dependencies = with pkgs.python3Packages; [
    anyio
    httpx
    mcp
    redis
    starlette
    uvicorn
  ];

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
  pythonImportsCheck = [
    "memory_mcp.wrapper"
    "memory_mcp.shim"
    "memory_mcp.cli"
    "memory_mcp.export"
    "memory_mcp.ingest_runner"
    "memory_mcp.ingest_sources"
    "memory_mcp.graph"
    "memory_mcp.internal_auth"
    "memory_mcp.registry"
    "memory_mcp.reconciler"
    "memory_mcp.llm_proxy"
  ];

  meta = {
    description = "Cross-machine memory MCP wrapper, shim, and CLI";
    mainProgram = "memory";
  };
}
