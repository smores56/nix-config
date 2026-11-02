# Jupyter server for Open WebUI's code interpreter. The server and every kernel
# it spawns run under the minimal `jupyter` agent-sandbox profile
# (modules/lib/agent-sandbox.{nix,sh}): one writable workspace, no secrets, no
# home config, no data tree. It runs as the invoking user and keeps the host
# network namespace, so Open WebUI reaches it on loopback.
#
# The token is a sops secret owned by the service user. The launcher reads it
# host-side and hands it to the sandbox as JUPYTER_TOKEN (jupyter_server honours
# it), so no token reaches the Nix store, the unit text, or the journal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.machine.username;

  sandbox = import ../lib/agent-sandbox.nix {
    inherit pkgs lib;
    isServer = builtins.elem "server" config.machine.profiles;
    isDarwin = false;
  };

  # Only what a kernel needs: the server, the IPython kernel, and the `jupyter`
  # dispatcher those two bring. A notebook that wants more has to install it
  # into the workspace.
  jupyter = pkgs.python3.withPackages (ps: [
    ps.jupyter-server
    ps.ipykernel
  ]);

  port = 8888;
in
{
  # Declared here rather than in modules/nixos/secrets.nix because this module
  # is server-profile-only and owns the only consumer; the value must exist in
  # secrets/smortress.yaml. mkDefault lets that file reclaim the declaration.
  sops.secrets.jupyter-token = {
    owner = lib.mkDefault username;
    mode = lib.mkDefault "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${sandbox.jupyterWorkspace} 0700 ${username} users -"
  ];

  systemd.services.jupyter = {
    description = "Jupyter server for the sandboxed Open WebUI code interpreter";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-nix.service" ];
    environment.JUPYTER_TOKEN_FILE = config.sops.secrets.jupyter-token.path;
    serviceConfig = {
      User = username;
      WorkingDirectory = sandbox.jupyterWorkspace;
      ExecStart = "${sandbox.jupyterSandbox}/bin/jupyter-sandbox ${jupyter}/bin/jupyter-server --no-browser --ServerApp.ip=127.0.0.1 --ServerApp.port=${toString port} --ServerApp.root_dir=${sandbox.jupyterWorkspace}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
