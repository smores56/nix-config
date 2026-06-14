{
  config,
  lib,
  pkgs,
  ...
}:
let
  d = config.dotfiles;
  cfg = d.paseo;
  homeDir = config.home.homeDirectory;

  fqdn = "${cfg.subdomain}.${d.webProxy.domain}";
  # The paseo binary and the agents it spawns (maki, brv) are installed manually
  # to assorted user bin dirs; resolve them all via PATH rather than hardcoding.
  binDir = if cfg.binDir != "" then cfg.binDir else "${homeDir}/.cache/.bun/bin";
  servicePath = lib.concatStringsSep ":" [
    "${pkgs.nodejs}/bin"
    binDir
    "${homeDir}/.bun/bin"
    "${homeDir}/.cache/.bun/bin"
    "${homeDir}/.npm-global/bin"
    "${homeDir}/.nix-profile/bin"
    "${homeDir}/.cargo/bin"
    "${homeDir}/.brv-cli/bin"
    "${homeDir}/.local/bin"
    "/run/current-system/sw/bin"
    "/run/wrappers/bin"
  ];

  # Daemon binds to loopback; web-proxy.nix fronts it at ${fqdn} with edge TLS.
  # hostnames clears the DNS-rebinding guard for that host; cors lets the hosted
  # web app (app.paseo.sh) and the tunnel origin drive it. Auth is NOT in this
  # file (it would land in the Nix store): set PASEO_PASSWORD via environmentFile
  # and/or gate ${fqdn} behind Cloudflare Access. The maki ACP provider is what
  # makes `paseo run --provider maki` (and maki's spawn_session tool) launch
  # `maki acp`; maki must be on the daemon's PATH below.
  paseoConfig = {
    "$schema" = "https://paseo.sh/schemas/paseo.config.v1.json";
    version = 1;
    daemon = {
      listen = "127.0.0.1:${toString cfg.port}";
      hostnames = [ ".${d.webProxy.domain}" ];
      cors.allowedOrigins = [
        "https://app.paseo.sh"
        "https://${fqdn}"
      ];
    };
    agents.providers.maki = {
      extends = "acp";
      label = "Maki";
      command = [
        "maki"
        "acp"
      ];
    };
  };
in
{
  config = lib.mkIf cfg.enable {
    # Written as a real (non-store) file so the daemon can persist runtime
    # toggles; rewritten on each switch (declarative wins), like pi-dashboard.
    home.activation.configurePaseo = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        mkdir -p "$HOME/.paseo"
        cat > "$HOME/.paseo/config.json" <<'PASEO_EOF'
        ${builtins.toJSON paseoConfig}
        PASEO_EOF
      '';
    };

    systemd.user.services.paseo = {
      Unit = {
        Description = "Paseo daemon (${fqdn})";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        # paseo, maki (ACP provider), and brv (maki's memory MCP) are installed
        # manually to various user bin dirs; servicePath unions them. ExecStart
        # runs through bash so `paseo` resolves via PATH (systemd does no PATH
        # lookup for ExecStart itself). --foreground keeps the daemon attached so
        # Type=simple supervises it; a bare `daemon start` self-backgrounds and
        # the foreground process exits, which systemd reads as a crash loop.
        Environment = "PATH=${servicePath}";
        ExecStart = "${pkgs.bash}/bin/bash -c 'exec paseo daemon start --foreground'";
        Restart = "on-failure";
        RestartSec = 5;
      }
      // lib.optionalAttrs (cfg.environmentFile != "") {
        # Required (fail-closed): the daemon won't start until this exists, so it
        # is never exposed unauthenticated. Holds PASEO_PASSWORD + provider keys.
        EnvironmentFile = cfg.environmentFile;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
