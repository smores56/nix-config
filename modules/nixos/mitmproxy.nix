{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.mitmproxy;

  # Domains that may receive any HTTP method (POST/PUT/DELETE/PATCH etc).
  # Everything else is limited to GET/HEAD/OPTIONS.
  anyMethodDomains = [
    # LLM APIs — personal
    "api.neuralwatt.com"
    "crof.ai"
    "token-plan-sgp.xiaomimimo.com"
    "api.exa.ai"
    "mcp.exa.ai"
    # LLM APIs — work
    "api.openai.com"
    "api.anthropic.com"
    "claude.ai"
    "platform.claude.com"
    "generativelanguage.googleapis.com"
    "aiplatform.googleapis.com"
    "api.groq.com"
    "api.mistral.ai"
    "api.cohere.com"
    "api.together.xyz"
    "api.fireworks.ai"
    "api.deepseek.com"
    "api.perplexity.ai"
    "inference.cerebras.ai"
    "openrouter.ai"
    "api.x.ai"
    # Package registries (need POST for publish/search)
    "pypi.org"
    "files.pythonhosted.org"
    "crates.io"
    "static.crates.io"
    "index.crates.io"
    "rubygems.org"
    "packagist.org"
    "repo.maven.apache.org"
    "repo1.maven.org"
    "plugins.gradle.org"
    "registry.npmjs.org"
    "registry.yarnpkg.com"
    # Auth / OAuth endpoints
    "auth.openai.com"
    "github.com"
    "api.github.com"
    "gitlab.com"
    "cloud.gitlab.com"
    # MCP / tooling
    "*.byterover.dev"
    # Cloud
    "api.cloudflare.com"
  ];

  filterScript = pkgs.writeText "mitmproxy-filter.py" ''
    import re

    ANY_METHOD_DOMAINS = {
    ${
      lib.concatStringsSep "\n" (
        map (d: "      ${builtins.toJSON d},") anyMethodDomains
      )
    }
    }

    # Wildcard suffixes (e.g. *.byterover.dev → any subdomain of byterover.dev)
    ANY_METHOD_SUFFIXES = [
      ".byterover.dev"
    ]

    SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}

    def request(flow):
        host = flow.request.pretty_host

        # Check exact match
        if host in ANY_METHOD_DOMAINS:
            return  # any method allowed

        # Check suffix match
        for suffix in ANY_METHOD_SUFFIXES:
            if host.endswith(suffix):
                return

        # Check wildcard domains
        for pattern in ANY_METHOD_DOMAINS:
            if pattern.startswith("*.") and host.endswith(pattern[1:]):
                return

        # Default: safe methods only
        if flow.request.method not in SAFE_METHODS:
            flow.response = http.Response.make(
                403,
                f"Method {flow.request.method} not allowed to {host}. "
                f"Only {', '.join(sorted(SAFE_METHODS))} requests are permitted by default.",
                {"Content-Type": "text/plain"},
            )
  '';
in
{
  options.dotfiles.mitmproxy = {
    enable = lib.mkEnableOption "mitmproxy L7 method-filtering proxy" // {
      default = true;
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for the mitmproxy to listen on.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ mitmproxy ];

    systemd.services.mitmproxy = {
      description = "mitmproxy L7 method-filtering proxy for nono sandbox egress";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # The proxy must be reachable before any nono session starts,
      # but nono sessions are user services.  multi-user.target is
      # conservative; a socket-activated version is fine if startup
      # ordering ever becomes an issue.
      bindsTo = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "mitmproxy";
        DynamicUser = true;
        StateDirectory = "mitmproxy";
        ExecStart = ''
          ${pkgs.mitmproxy}/bin/mitmdump \
            --listen-port ${toString cfg.port} \
            --set block_global=false \
            --set ssl_insecure=false \
            -s ${filterScript}
        '';
        Restart = "on-failure";
        RestartSec = "5";
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        CapabilityBoundingSet = "";
        # mitmproxy needs network access
        PrivateNetwork = false;
      };
    };
  };
}
