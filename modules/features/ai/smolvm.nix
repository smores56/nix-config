{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.smolvm;

  codeRoot = config.dotfiles.codeRoot;
  sharedBinDir = "${config.xdg.dataHome}/smolvm-shared/bin";

  tomlFormat = pkgs.formats.toml { };

  # Smolfile for the persistent agent VM. No `cmd` — agents run via
  # `machine exec`, so `machine start` returns immediately after boot.
  # Shared bin mounts to /root/.local/bin (NOT /usr/local/bin, which
  # would shadow the agent rootfs's crane binary and break image pulls).
  smolfile = tomlFormat.generate "agent.smolfile" {
    image = "alpine:3.21";
    net = true;
    cpus = 2;
    memory = 1024;
    overlay = 10;
    env = [
      "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ];
    volumes = [
      "${sharedBinDir}:/root/.local/bin"
      "${codeRoot}:/root/code"
    ];
  };

  launcher = pkgs.writeShellScriptBin "smolvm-agent" ''
    set -euo pipefail

    smolvm=${pkgs.smolvm}/bin/smolvm
    name="agent"

    # Create the persistent VM if it doesn't exist.
    if ! $smolvm machine status --name "$name" >/dev/null 2>&1; then
      $smolvm machine create "$name" --smolfile ${smolfile}
    fi

    # Start if not running. `machine start` returns immediately for VMs
    # without a cmd (our Smolfile has none — agents run via `machine exec`).
    state=$($smolvm machine status --name "$name" --json 2>/dev/null | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
    if [ "$state" != "running" ]; then
      $smolvm machine start --name "$name" >/dev/null
    fi

    exec $smolvm machine exec --name "$name" -i -t -- "$@"
''
  ;
in
{
  options.dotfiles.smolvm = {
    enable =
      lib.mkEnableOption "smolvm sandbox for coding agents (maki/omp) with per-instance kernel tmpfs"
      // {
        default = true;
      };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.smolvm
      launcher
    ];

    # Shared bin dir mounted writable into every agent VM at /root/.local/bin.
    # maki/omp are installed here via `maki update` / `omp update` (self-updates
    # swap the binary in place via current_exe()). The dir is on the virtiofs
    # mount, so updates persist to the host.
    home.activation.createSmolvmSharedBin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${sharedBinDir}
    '';
  };
}
