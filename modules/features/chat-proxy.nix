# Blessed devices reach agent.sammohr.dev (Open WebUI) without the Cloudflare Access one-time PIN:
# service tokens travel as HTTP headers, which no browser sends, so a loopback Caddy adds this
# device's token. `cloudflared access tcp` cannot stand in for it: it dials a TCP ingress, not the
# HTTP one the browser needs. Non-blessed devices keep the email OTP policy as fallback.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Per-device Access service token from sops (Client ID, then Client Secret on two lines); a
  # device without it fails closed, exactly like `cloudflared-access`.
  tokenPath = import ../lib/secret-path.nix config "cloudflare-access-ssh-token";

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # A client-side listener, so it stays out of modules/ports.nix, which pairs loopback services
  # with their tunnel ingress.
  port = 8787;

  caddyfile = pkgs.writeText "chat-proxy.Caddyfile" ''
    {
      admin off
    }

    # Open WebUI serves relative paths, so the browser stays on this origin. Its rare absolute
    # redirects would land on the public hostname and show the PIN page; rewriting Location is
    # rejected because Caddy's RE2 cannot exclude Access's own login path and a blind rewrite
    # loops on a revoked token.
    http://127.0.0.1:${toString port} {
      reverse_proxy https://agent.sammohr.dev {
        # Caddy forwards the incoming Host by default, so without this the edge sees 127.0.0.1
        # and rejects the request (Host must match the tunnel hostname).
        header_up Host agent.sammohr.dev
        header_up Cf-Access-Client-Id {env.CF_ACCESS_CLIENT_ID}
        header_up Cf-Access-Client-Secret {env.CF_ACCESS_CLIENT_SECRET}
      }
    }
  '';

  # The unit names only this wrapper; the token is read at start, so a rotation needs no wrapper
  # rebuild (re-deploy the secret, then restart the unit) and no unit ever holds the value.
  chatProxy = pkgs.writeShellApplication {
    name = "chat-proxy";
    runtimeInputs = [ pkgs.caddy ];
    text = ''
      token_file="${tokenPath}"

      {
        IFS= read -r token_id || true
        IFS= read -r token_secret || true
      } 2>/dev/null < "$token_file" || true

      if [ -z "''${token_id:-}" ] || [ -z "''${token_secret:-}" ]; then
        echo "chat-proxy: missing or malformed Cloudflare Access token (two lines: Client ID, Client Secret) at $token_file" >&2
        exit 1
      fi

      export CF_ACCESS_CLIENT_ID="$token_id"
      export CF_ACCESS_CLIENT_SECRET="$token_secret"

      exec caddy run --config ${caddyfile} --adapter caddyfile
    '';
  };
in
{
  systemd.user.services."chat-proxy" =
    lib.mkIf (!(config.kanbeiSplit.cutover.enable or false) && !isDarwin)
      {
        Unit = {
          Description = "Loopback Caddy that adds this device's Cloudflare Access token for agent.sammohr.dev";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          ExecStart = "${chatProxy}/bin/chat-proxy";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };

  launchd.agents."chat-proxy" = lib.mkIf (!(config.kanbeiSplit.cutover.enable or false) && isDarwin) {
    enable = true;
    config = {
      ProgramArguments = [ "${chatProxy}/bin/chat-proxy" ];
      EnvironmentVariables.HOME = config.home.homeDirectory;
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/chat-proxy.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/chat-proxy.log";
    };
  };
}
