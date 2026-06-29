{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.smolvm;

  codeRoot = config.dotfiles.codeRoot;
  sharedDir = "${config.xdg.dataHome}/smolvm-shared";
  sharedBinDir = "${sharedDir}/bin";
  configDir = "${sharedDir}/config";

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
  # Config dir mounts read-only at /mnt/host-config — Nix-managed config
  # dereference (symlinks into /nix/store resolved on the host side).
  smolfile = tomlFormat.generate "agent.smolfile" {
    image = "debian:bookworm-slim";
    net = true;
    cpus = 2;
    memory = 1024;
    overlay = 10;
    env = [
      "BUN_INSTALL=/root/.bun"
      "MAKI_INSTALL_DIR=/root/.local/bin"
      "PATH=/root/.bun/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ];
    volumes = [
      "${sharedBinDir}:/root/.local/bin"
      "${configDir}:/mnt/host-config:ro"
      "${codeRoot}:/root/code"
    ];
  };

  # Idempotent provisioning command run inside the VM. Ensures bun,
  # omp, and maki are installed into the persistent overlay (/root/.bun,
  # /root/.local/bin), so the install survives VM stop/start.
  #
  # smolvm machine exec doesn't pipe stdin reliably, so we pass the
  # script via `bash -c`.
  provisionScript = ''
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # Seed config from the read-only host mount into the overlay, so
    # Nix-managed symlinks (into /nix/store, which doesn't exist in the
    # VM) are dereferenced and the real files land in /root/.config and
    # /root/.omp. Only copies files that are missing or changed.
    sync_config() {
      local src="$1" dst="$2"
      mkdir -p "$dst"
      cp -ruL "$src"/. "$dst"/ 2>/dev/null || true
    }
    sync_config /mnt/host-config/maki /root/.config/maki
    sync_config /mnt/host-config/omp /root/.omp

    # Bun + omp (glibc-linked native addons, not static).
    if [ ! -x /root/.bun/bin/bun ]; then
      apt-get update -qq
      apt-get install -y -qq curl unzip bash
      curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL=/root/.bun
    export PATH="$BUN_INSTALL/bin:$PATH"
    command -v omp >/dev/null 2>&1 || bun add -g @oh-my-pi/pi-coding-agent

    # maki (static musl binary). Installed into the shared virtiofs bin
    # mount, so it persists on the host and self-updates via `maki update`.
    if [ ! -x /root/.local/bin/maki ]; then
      apt-get install -y -qq curl >/dev/null 2>&1 || true
      curl -fsSL https://maki.sh/install.sh | MAKI_INSTALL_DIR=/root/.local/bin sh
    fi
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

    # Provision bun + omp + maki inside the VM (idempotent — skips when present).
    $smolvm machine exec --name "$name" -- /bin/bash -c ${lib.escapeShellArg provisionScript}

    # Forward MAKI_INSTALL_DIR so `maki update` writes to the shared
    # virtiofs bin mount, not the default /usr/local/bin.
    env_args=(--env "MAKI_INSTALL_DIR=/root/.local/bin")

    # Forward API key env vars from the host shell into the VM. Both
    # omp (models.yml references env var names like "apiKey":"FOO_API_KEY")
    # and maki (provider scripts resolve env vars at runtime) use env-var-
    # based auth, so no secret files need to be mounted.
    for var in $(env | sed -n 's/^\([A-Z][A-Z0-9_]*_API_KEY\)=.*/\1/p'); do
      env_args+=(--env "$var=$(printenv "$var")")
    done

    exec $smolvm machine exec --name "$name" -i -t "''${env_args[@]}" -- "$@"
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

    # Dereference Nix-managed config symlinks (into /nix/store) into a
    # staging dir, mounted read-only into the VM at /mnt/host-config.
    # The /nix/store paths don't exist inside the VM, so symlinks would
    # be broken. This runs on every home-manager switch to pick up
    # config changes.
    home.activation.syncSmolvmConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/maki ${configDir}/omp
      cp -rL ${config.home.homeDirectory}/.config/maki/. ${configDir}/maki/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.omp/. ${configDir}/omp/ 2>/dev/null || true
      chmod -R u+w ${configDir}
    '';
  };
}
