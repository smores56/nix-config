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
  #
  # Image is debian (not alpine): omp's native addons (pi_natives) are
  # glibc-linked and need glibc symbols that musl/gcompat can't provide.
  # maki is a static binary, so it works under any libc.
  #
  # Shared bin mounts to /root/.local/bin (NOT /usr/local/bin, which
  # would shadow the agent rootfs's crane binary and break image pulls).
  smolfile = tomlFormat.generate "agent.smolfile" {
    image = "debian:bookworm-slim";
    net = true;
    cpus = 2;
    memory = 1024;
    overlay = 10;
    env = [
      "BUN_INSTALL=/root/.bun"
      "PATH=/root/.bun/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ];
    volumes = [
      "${sharedBinDir}:/root/.local/bin"
      "${codeRoot}:/root/code"
    ];
  };

  # Idempotent provisioning command run inside the VM. Ensures bun and
  # omp are installed into the persistent overlay (/root/.bun), so the
  # install survives VM stop/start. maki lives in the shared virtiofs
  # mount (/root/.local/bin), installed separately via `maki update`.
  #
  # smolvm machine exec doesn't pipe stdin reliably, so we pass the
  # script via `bash -c`.
  provisionScript = ''
    set -e
    export DEBIAN_FRONTEND=noninteractive
    if [ ! -x /root/.bun/bin/bun ]; then
      apt-get update -qq
      apt-get install -y -qq curl unzip bash
      curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL=/root/.bun
    export PATH="$BUN_INSTALL/bin:$PATH"
    command -v omp >/dev/null 2>&1 || bun add -g @oh-my-pi/pi-coding-agent
  '';

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

    # Provision bun + omp inside the VM (idempotent — skips when present).
    $smolvm machine exec --name "$name" -- /bin/bash -c ${lib.escapeShellArg provisionScript}

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
    # maki lives here as a static binary, self-updated via `maki update`.
    home.activation.createSmolvmSharedBin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${sharedBinDir}
    '';
  };
}
