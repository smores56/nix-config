# Jupyter server for Open WebUI's code interpreter. Server and kernels run under
# the bwrap sandbox in modules/lib/jupyter-sandbox.{nix,sh}:
# one writable workspace, no secrets or home config. It keeps the host network
# namespace so Open WebUI reaches it on loopback.
#
# The launcher reads the sops token host-side and passes it as JUPYTER_TOKEN, so it
# never reaches the store, unit text, or journal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.machine.username;

  sandbox = import ../lib/jupyter-sandbox.nix {
    inherit pkgs lib;
  };

  # Only what a kernel needs; anything more is installed into the workspace.
  jupyter = pkgs.python3.withPackages (ps: [
    ps.jupyter-server
    ps.ipykernel
  ]);

  port = 8888;
in
{
  # Declared here because only this server-profile module consumes it; the value must
  # exist in secrets/smortress.yaml. mkDefault lets that file reclaim it.
  sops.secrets.jupyter-token = {
    owner = lib.mkDefault username;
    mode = lib.mkDefault "0400";
    # Open WebUI bakes the token into its rendered env file; rotating without
    # restarting it leaves the code interpreter 401ing.
    restartUnits =
      lib.optional (config.systemd.services ? jupyter) "jupyter.service"
      ++ lib.optional (config.systemd.services ? open-webui) "open-webui.service";
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
