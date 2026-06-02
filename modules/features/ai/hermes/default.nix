{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.hermes;
  enabled = cfg.enable && pkgs.stdenv.isLinux;

  homeDir = config.home.homeDirectory;
  hermesHome = "${homeDir}/.hermes";
  installDir = "${hermesHome}/hermes-agent";
  hermesBin = "${installDir}/venv/bin/hermes";

  # Docker client lives in the system profile via virtualisation.docker.
  dockerBin = "/run/current-system/sw/bin/docker";

  # ── Sandbox image ────────────────────────────────────────────────────────
  # A generous, reproducible toolset baked into the container so "lots of
  # tools are available" without ever exposing the host filesystem. Extend via
  # dotfiles.hermes.extraPackages (e.g. go, rustup). The image keeps state only
  # in /workspace and /root, which Hermes bind-mounts per-task under
  # ~/.hermes/sandboxes/, so file access stays caged per session/profile.
  basePackages = with pkgs; [
    bashInteractive
    coreutils-full
    findutils
    gnugrep
    gnused
    gawk
    which
    diffutils
    patch
    gnutar
    gzip
    bzip2
    xz
    zip
    unzip
    less
    procps
    util-linux
    iproute2
    iputils
    curl
    wget
    cacert
    openssh
    git
    jq
    yq-go
    ripgrep
    fd
    fzf
    tree
    python3
    nodejs_22
    uv
    gcc
    gnumake
    pkg-config
    # Image scaffolding: /bin/sh, /usr/bin/env, /etc/ssl, /etc/passwd+group.
    dockerTools.binSh
    dockerTools.usrBinEnv
    dockerTools.caCertificates
    dockerTools.fakeNss
  ];

  sandboxRoot = pkgs.buildEnv {
    name = "hermes-sandbox-root";
    paths = basePackages ++ cfg.extraPackages;
    pathsToLink = [
      "/bin"
      "/usr/bin"
      "/lib"
      "/share"
      "/etc"
    ];
    ignoreCollisions = true;
  };

  sandboxImage = pkgs.dockerTools.buildLayeredImage {
    name = "hermes-sandbox";
    # Null tag → content-addressed tag, so changing the toolset changes the
    # ref and the activation reload below actually refreshes the daemon image.
    tag = null;
    contents = [ sandboxRoot ];
    config = {
      Cmd = [ "/bin/bash" ];
      WorkingDir = "/workspace";
      Env = [
        "PATH=/bin:/usr/bin"
        "HOME=/root"
        "LANG=C.UTF-8"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
        "NODE_PATH=/lib/node_modules"
      ];
    };
  };

  imageRef =
    if cfg.useNixImage then "${sandboxImage.imageName}:${sandboxImage.imageTag}" else cfg.registryImage;

  # PATH for the bootstrap installer: hand it every tool it would otherwise try
  # to download, so the curl|bash installer stays offline-friendly under Nix.
  installerPath = lib.makeBinPath [
    pkgs.uv
    pkgs.git
    pkgs.nodejs_22
    pkgs.ripgrep
    pkgs.ffmpeg
    pkgs.curl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.gnutar
    pkgs.gzip
    pkgs.which
    pkgs.cacert
  ];
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # ── Helper commands ────────────────────────────────────────────────────────
  hermesRepo = pkgs.writeShellScriptBin "hermes-repo" ''
    set -euo pipefail
    export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${homeDir}/.local/bin:${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.git
        pkgs.gnused
      ]
    }:$PATH"

    HERMES=${lib.escapeShellArg hermesBin}
    if [ ! -x "$HERMES" ]; then
      echo "hermes is not installed yet — run 'home-manager switch' first." >&2
      exit 127
    fi

    target="''${1:-}"
    if [ -n "$target" ]; then
      repo="$(realpath "$target")"
    else
      repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    if [ ! -d "$repo" ]; then
      echo "Not a directory: $repo" >&2
      exit 1
    fi

    # Profile id = sanitized repo basename (Hermes requires [a-z0-9][a-z0-9_-]{0,63}).
    name="$(basename "$repo" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/^[^a-z0-9]*//' | cut -c1-64)"
    [ -n "$name" ] || name="repo"

    # Each repo gets its own profile → its own labeled container + its own
    # sessions/memory/skills. --clone inherits the docker sandbox config.
    # Errors (profile already exists) are intentionally ignored.
    "$HERMES" profile create "$name" --clone >/dev/null 2>&1 || true

    # Mount ONLY this repo into the cage, owned by the host user, and nothing
    # else of the host filesystem.
    export TERMINAL_DOCKER_VOLUMES="[\"$repo:/workspace\"]"
    export TERMINAL_DOCKER_RUN_AS_HOST_USER=true

    echo "hermes profile '$name' → sandbox /workspace = $repo" >&2
    exec "$HERMES" -p "$name" chat
  '';

  hermesSandboxGc = pkgs.writeShellScriptBin "hermes-sandbox-gc" ''
    set -euo pipefail
    export PATH="/run/current-system/sw/bin:/run/wrappers/bin:$PATH"
    ids="$(${dockerBin} ps -aq --filter label=hermes-agent=1 || true)"
    if [ -z "$ids" ]; then
      echo "No Hermes sandbox containers to remove."
      exit 0
    fi
    echo "$ids" | xargs -r ${dockerBin} rm -f
  '';

  tailscaleHttpsPort = toString cfg.dashboard.tailscaleHttpsPort;
  dashboardUrl = "http://127.0.0.1:${toString cfg.dashboard.port}";
  hermesDashboardServe = pkgs.writeShellScriptBin "hermes-dashboard-serve" ''
    set -euo pipefail
    export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${
      lib.makeBinPath [ pkgs.coreutils ]
    }:$PATH"

    systemctl --user restart hermes-dashboard.service
    systemctl --user is-active --quiet hermes-dashboard.service

    set +e
    ${pkgs.coreutils}/bin/timeout 30s ${pkgs.tailscale}/bin/tailscale serve \
      --yes \
      --bg \
      --https=${tailscaleHttpsPort} \
      ${lib.escapeShellArg dashboardUrl}
    serve_status="$?"
    set -e
    if [ "$serve_status" -ne 0 ]; then
      if [ "$serve_status" -eq 124 ]; then
        echo "tailscale serve timed out. If Serve is disabled, enable it in the Tailscale admin console, then rerun hermes-dashboard-serve." >&2
      fi
      exit "$serve_status"
    fi

    ${pkgs.tailscale}/bin/tailscale serve status
  '';
in
{
  config = lib.mkIf enabled {
    home = {
      packages = [
        pkgs.uv
        hermesRepo
        hermesSandboxGc
      ]
      ++ lib.optional cfg.dashboard.tailscaleServe hermesDashboardServe;

      # Bootstrap the upstream Hermes installer (uv venv + hash-locked deps,
      # node, ripgrep, ffmpeg) when the checkout is missing. Skips the wizard and
      # browser binaries; the model/keys are configured later via the dashboard
      # or `hermes model`.
      activation = {
        installHermes = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          export PATH="${installerPath}:${homeDir}/.local/bin:$PATH"
          export UV_NO_CONFIG=1
          export SSL_CERT_FILE=${caBundle}
          export GIT_SSL_CAINFO=${caBundle}
          if [ -x ${lib.escapeShellArg hermesBin} ]; then
            echo "[hermes] already installed at ${hermesBin}"
          else
            echo "[hermes] installing Hermes Agent (skip-setup, skip-browser)…"
            ${pkgs.curl}/bin/curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
              | ${pkgs.bash}/bin/bash -s -- --skip-setup --skip-browser --non-interactive \
              || echo "[hermes] installer failed; re-run 'home-manager switch' or run the installer manually" >&2
          fi
        '';

        # Load the Nix-built sandbox image into the daemon when its ref changes.
        loadHermesImage = lib.mkIf cfg.useNixImage (
          lib.hm.dag.entryAfter [ "linkGeneration" ] ''
            export PATH="/run/current-system/sw/bin:/run/wrappers/bin:$PATH"
            if ${dockerBin} image inspect ${lib.escapeShellArg imageRef} >/dev/null 2>&1; then
              echo "[hermes] sandbox image ${imageRef} present"
            else
              echo "[hermes] loading sandbox image ${imageRef}…"
              ${dockerBin} load -i ${sandboxImage} \
                || echo "[hermes] docker load failed — is dockerd running and are you in the 'docker' group? (re-login after first nixos-rebuild)" >&2
            fi
          ''
        );

        # Point the default profile at the hardened Docker sandbox. config.yaml
        # stays writable so the dashboard's Config editor still works; per-repo
        # profiles inherit these via `profile create --clone`.
        configureHermes =
          lib.hm.dag.entryAfter
            [
              "linkGeneration"
              "installHermes"
              "loadHermesImage"
            ]
            ''
              export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${
                lib.makeBinPath [ pkgs.coreutils ]
              }:$PATH"
              HERMES=${lib.escapeShellArg hermesBin}
              if [ ! -x "$HERMES" ]; then
                echo "[hermes] not installed yet; skipping config"
              else
                "$HERMES" config set terminal.backend docker || true
                "$HERMES" config set terminal.docker_image ${lib.escapeShellArg imageRef} || true
                "$HERMES" config set terminal.docker_mount_cwd_to_workspace false || true
                "$HERMES" config set terminal.docker_run_as_host_user false || true
                "$HERMES" config set terminal.container_persistent true || true
                "$HERMES" config set terminal.docker_persist_across_processes true || true
                "$HERMES" config set terminal.container_cpu ${toString cfg.containerCpu} || true
                "$HERMES" config set terminal.container_memory ${toString cfg.containerMemory} || true
                "$HERMES" config set terminal.container_disk ${toString cfg.containerDisk} || true
                "$HERMES" config set approvals.mode smart || true
                echo "[hermes] configured Docker sandbox backend (image ${imageRef})"
              fi
            '';
      };
    };

    programs.fish.shellAbbrs = {
      hr = "hermes-repo";
    };
  };
}
