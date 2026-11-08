# One binary for every HTTP capability: Credential injection, route allowlist and streaming.
{ pkgs, lib ? pkgs.lib }:
pkgs.python3Packages.buildPythonApplication {
  pname = "agent-broker";
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
  dependencies = [ pkgs.python3Packages.aiohttp ];

  doCheck = false;
  pythonImportsCheck = [ "agent_broker" ];

  meta = {
    description = "Credential-injecting capability broker for the agent VM";
    mainProgram = "agent-broker";
  };
}
