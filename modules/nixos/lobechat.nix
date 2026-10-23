# Phone-first LobeChat (LobeHub 2.x) over the shared Graphiti memory stack.
#
# One container serves the PWA behind Cloudflare Access; Postgres and RustFS stay
# on loopback. LobeChat reaches Graphiti through the existing memory wrapper, not
# through a second memory system: its built-in Memory is disabled per user, and
# the MCP server is configured in the UI (see docs/manual-steps.md).
#
# Secrets are generated once under /var/lib/lobechat/secrets instead of being
# added to the sops store. They never enter the Nix store, and a missing key
# cannot hard-fail activation. Rotating one means deleting it, restarting
# lobechat-secrets, and restarting the stack; lobechat-db-init re-applies a
# rotated database password.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.lobechat;
  ports = import ../ports.nix;

  stateDir = "/var/lib/lobechat";
  secretsDir = "${stateDir}/secrets";
  runtimeDir = "/run/lobechat";
  rustfsData = "/var/lib/rustfs";
  bucket = "lobe";

  # LobeChat asks for 1024 dimensions on every knowledge-base call and its
  # pgvector column is fixed at 1024, so both embedders answer at that width:
  # bge-m3 natively, qwen3-embedding-8b truncated by the API (verified local).
  # Follow `memory.embedder` so the KB and the graph never disagree about the
  # model behind a vector; changing it requires re-indexing the KB.
  embedding =
    if config.memory.embedder == "neuralwatt" then
      {
        model = "qwen3-embedding-8b";
        url = "http://127.0.0.1:${toString ports.memoryLlmProxy}/v1";
      }
    else
      {
        model = "bge-m3";
        url = "http://127.0.0.1:${toString ports.memoryEmbed}/v1";
      };

  # Multi-arch index digests: a tag re-push upstream cannot silently change the
  # bytes. LobeHub v2 is server-DB-only; the frozen 1.x `lobe-chat-database`
  # images still expect the removed NextAuth variables.
  lobechatImage = "lobehub/lobehub:2.2.20@sha256:8a46ff8c76aef731b6d228d92edfc384aa77335593187b670be23ce78a690716";
  rustfsImage = "rustfs/rustfs:1.0.3@sha256:9ca9559533b537d10482fe923288b676ad08f92a7069d9a17327fbae3cab688b";

  secretsScript = pkgs.writeShellScript "lobechat-secrets" ''
    set -euo pipefail
    install -d -m 0700 ${secretsDir}

    # base64 is fine for web secrets; S3 credentials stay hex because SigV4
    # treats the access key as an identifier, not an opaque string.
    gen_b64() {
      local path=$1
      if [ ! -s "$path" ]; then
        umask 077
        ${pkgs.openssl}/bin/openssl rand -base64 32 > "$path.tmp"
        mv "$path.tmp" "$path"
      fi
    }
    gen_hex() {
      local path=$1 bytes=$2
      if [ ! -s "$path" ]; then
        umask 077
        ${pkgs.openssl}/bin/openssl rand -hex "$bytes" > "$path.tmp"
        mv "$path.tmp" "$path"
      fi
    }

    gen_b64 ${secretsDir}/auth-secret
    gen_b64 ${secretsDir}/key-vaults-secret
    gen_hex ${secretsDir}/db-password 32
    gen_hex ${secretsDir}/s3-access-key 24
    gen_hex ${secretsDir}/s3-secret-key 32

    # Internal async calls (knowledge-base ingestion, share uploads) sign a
    # JWT with an RS256 key; without it those calls fail even though the server
    # starts.
    if [ ! -s ${secretsDir}/jwks-key ]; then
      umask 077
      ${pkgs.nodejs}/bin/node -e '
        const c = require("crypto");
        const meta = { alg: "RS256", kid: c.randomBytes(8).toString("hex"), use: "sig" };
        const { privateKey } = c.generateKeyPairSync("rsa", { modulusLength: 2048 });
        console.log(JSON.stringify({ keys: [{ ...privateKey.export({ format: "jwk" }), ...meta }] }));
      ' > ${secretsDir}/jwks-key.tmp
      mv ${secretsDir}/jwks-key.tmp ${secretsDir}/jwks-key
    fi

    chown root:root ${secretsDir}
    chmod 0700 ${secretsDir}
    chown root:root \
      ${secretsDir}/auth-secret \
      ${secretsDir}/key-vaults-secret \
      ${secretsDir}/jwks-key \
      ${secretsDir}/s3-access-key \
      ${secretsDir}/s3-secret-key
    chmod 0600 \
      ${secretsDir}/auth-secret \
      ${secretsDir}/key-vaults-secret \
      ${secretsDir}/jwks-key \
      ${secretsDir}/s3-access-key \
      ${secretsDir}/s3-secret-key
    # The database init unit runs as postgres and cannot traverse the root-only
    # state tree; hand it a readable copy under /run instead.
    install -d -m 0750 -o root -g postgres ${runtimeDir}
    install -m 0400 -o postgres -g postgres \
      ${secretsDir}/db-password ${runtimeDir}/db-password
  '';

  # One env file for podman: values are read at start, never baked into the
  # store or the unit. The password is hex, so it needs no URL escaping.
  lobechatEnvScript = pkgs.writeShellScript "lobechat-env" ''
    set -euo pipefail
    umask 077
    install -d -m 0750 -o root -g postgres ${runtimeDir}
    {
      printf 'AUTH_SECRET=%s\n' "$(cat ${secretsDir}/auth-secret)"
      printf 'KEY_VAULTS_SECRET=%s\n' "$(cat ${secretsDir}/key-vaults-secret)"
      printf 'JWKS_KEY=%s\n' "$(cat ${secretsDir}/jwks-key)"
      printf 'DATABASE_URL=postgresql://lobechat:%s@127.0.0.1:5432/lobechat\n' \
        "$(cat ${secretsDir}/db-password)"
      printf 'S3_ACCESS_KEY_ID=%s\n' "$(cat ${secretsDir}/s3-access-key)"
      printf 'S3_SECRET_ACCESS_KEY=%s\n' "$(cat ${secretsDir}/s3-secret-key)"
      printf 'BRAVE_API_KEY=%s\n' "$(cat ${config.sops.secrets.brave-api-key.path})"
      printf 'OPENAI_API_KEY=%s\n' "$(cat ${config.sops.secrets.neuralwatt-api-key.path})"
    } > ${runtimeDir}/env
    chmod 0600 ${runtimeDir}/env
  '';

  rustfsEnvScript = pkgs.writeShellScript "rustfs-env" ''
    set -euo pipefail
    umask 077
    install -d -m 0750 -o root -g postgres ${runtimeDir}
    {
      printf 'RUSTFS_ACCESS_KEY=%s\n' "$(cat ${secretsDir}/s3-access-key)"
      printf 'RUSTFS_SECRET_KEY=%s\n' "$(cat ${secretsDir}/s3-secret-key)"
    } > ${runtimeDir}/rustfs.env
    chmod 0600 ${runtimeDir}/rustfs.env
  '';

  # `ensureUsers` cannot set a password without putting it in the store, so the
  # role password is applied from the generated file. The extension is created
  # as the superuser because the migration role is deliberately not one.
  dbInitScript = pkgs.writeShellScript "lobechat-db-init" ''
    set -euo pipefail
    password=$(cat ${runtimeDir}/db-password)
    {
      printf "\\set pw '%s'\n" "$password"
      echo "ALTER ROLE lobechat WITH LOGIN PASSWORD :'pw';"
    } | ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -d postgres
    ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -d lobechat \
      -c 'CREATE EXTENSION IF NOT EXISTS vector'
  '';

  # LobeChat expects the bucket to exist; it does not create it. mc is smaller
  # than the AWS CLI and speaks path-style against RustFS.
  bucketScript = pkgs.writeShellScript "lobechat-s3-bucket" ''
    set -euo pipefail
    install -d -m 0700 ${runtimeDir}/mc
    export MC_CONFIG_DIR=${runtimeDir}/mc
    for _ in $(seq 120); do
      ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString ports.rustfs}/health >/dev/null 2>&1 && break
      sleep 1
    done
    ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString ports.rustfs}/health >/dev/null

    export MC_HOST_local="http://$(cat ${secretsDir}/s3-access-key):$(cat ${secretsDir}/s3-secret-key)@127.0.0.1:${toString ports.rustfs}"
    ${pkgs.minio-client}/bin/mc mb --ignore-existing local/${bucket}
  '';

  readinessScript = pkgs.writeShellScript "lobechat-wait" ''
    for _ in $(seq 300); do
      ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString ports.lobechat}/ >/dev/null && exit 0
      sleep 2
    done
    echo "lobechat: no answer on 127.0.0.1:${toString ports.lobechat} after 600s" >&2
    exit 1
  '';
in
{
  options.lobechat.enable = lib.mkEnableOption "the phone-first LobeChat deployment over Graphiti memory";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.webProxy.enable;
        message = "lobechat requires webProxy.enable: the PWA is reached only through the tunnel and Access.";
      }
      {
        assertion = config.memory.enable;
        message = "lobechat requires memory.enable: it reuses memory's Graphiti MCP wrapper and embedder.";
      }
      {
        assertion = config.sops.secrets ? brave-api-key && config.sops.secrets ? neuralwatt-api-key;
        message = "lobechat requires the brave-api-key and neuralwatt-api-key sops secrets.";
      }
    ];

    services.postgresql = {
      enable = true;
      ensureDatabases = [ "lobechat" ];
      ensureUsers = [
        {
          name = "lobechat";
          ensureDBOwnership = true;
          ensureClauses.login = true;
        }
      ];
      # Immich also installs pgvector on smortress; the duplicate is harmless
      # and keeps this module self-contained.
      extensions = ps: [ ps.pgvector ];
    };

    systemd.tmpfiles.rules = [
      # RustFS runs as uid/gid 10001 in the image.
      "d ${rustfsData} 0700 10001 10001 -"
    ];

    systemd.services.lobechat-secrets = {
      description = "Generate the LobeChat, RustFS, and database secrets";
      wantedBy = [ "multi-user.target" ];
      before = [
        "podman-rustfs.service"
        "podman-lobechat.service"
        "lobechat-db-init.service"
        "lobechat-s3-bucket.service"
      ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "lobechat";
        StateDirectoryMode = "0750";
        ExecStart = secretsScript;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    systemd.services.lobechat-db-init = {
      description = "Prepare the lobechat database role and pgvector extension";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "postgresql.service"
        "postgresql-setup.service"
        "lobechat-secrets.service"
      ];
      after = [
        "postgresql.service"
        "postgresql-setup.service"
        "lobechat-secrets.service"
      ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        ExecStart = dbInitScript;
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };

    systemd.services.lobechat-s3-bucket = {
      description = "Create the LobeChat S3 bucket in RustFS";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "podman-rustfs.service"
        "lobechat-secrets.service"
      ];
      after = [
        "podman-rustfs.service"
        "lobechat-secrets.service"
      ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = bucketScript;
        TimeoutStartSec = "5min";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers = {
      rustfs = {
        image = rustfsImage;
        extraOptions = [
          # Host networking keeps the S3 endpoint on loopback: only the tunnel
          # ingress and the LobeChat container can reach it.
          "--network=host"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
        ];
        volumes = [ "${rustfsData}:/data" ];
        environment = {
          RUSTFS_VOLUMES = "/data";
          # The image defaults to :9000 on every interface.
          RUSTFS_ADDRESS = "127.0.0.1:${toString ports.rustfs}";
          # The embedded console is not exposed; the API is the only surface.
          RUSTFS_CONSOLE_ENABLE = "false";
          # Browser uploads are presigned PUTs, so the S3 origin needs CORS.
          RUSTFS_CORS_ALLOWED_ORIGINS = "https://chat.${config.webProxy.domain}";
        };
        environmentFiles = [ "${runtimeDir}/rustfs.env" ];
      };

      lobechat = {
        image = lobechatImage;
        extraOptions = [
          "--network=host"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
        ];
        environment = {
          # Next.js standalone binds HOSTNAME; the image default is 0.0.0.0.
          HOSTNAME = "127.0.0.1";
          PORT = toString ports.lobechat;
          # No trailing slash: startup rejects it.
          APP_URL = "https://chat.${config.webProxy.domain}";
          INTERNAL_APP_URL = "http://127.0.0.1:${toString ports.lobechat}";
          # Better Auth: email/password only, and only this address may be
          # created. Cloudflare Access is the outer layer.
          AUTH_ALLOWED_EMAILS = config.user.email;
          # The image migrates on start when DATABASE_DRIVER is set. pg_like is
          # required because the host Postgres has no ParadeDB `pg_search`.
          DATABASE_DRIVER = "node";
          FTS_SEARCH_PROVIDER = "pg_like";
          # Presigned URLs use the public endpoint; server-side calls stay on
          # loopback. Browser uploads still reach the public endpoint, so the
          # Access session must cover it.
          S3_ENDPOINT = "https://s3.${config.webProxy.domain}";
          S3_INTERNAL_ENDPOINT = "http://127.0.0.1:${toString ports.rustfs}";
          S3_BUCKET = bucket;
          S3_ENABLE_PATH_STYLE = "1";
          S3_SET_ACL = "0";
          S3_REGION = "us-east-1";
          SEARCH_PROVIDERS = "brave";
          # Knowledge-base embeddings: an OpenAI-compatible server that is not
          # the chat provider, so it rides the NewAPI slot. LobeChat sends
          # `dimensions: 1024` on every call, matching its schema's column.
          DEFAULT_FILES_CONFIG = "embedding_model=newapi/${embedding.model}";
          NEWAPI_API_KEY = "none";
          NEWAPI_PROXY_URL = embedding.url;
          # Chat: Neuralwatt by default; the local qwen is the fallback.
          OPENAI_PROXY_URL = "https://api.neuralwatt.com/v1";
          OPENAI_MODEL_LIST = "-all,+deepseek-v4.1-flash";
          DEFAULT_AGENT_CONFIG = "model=deepseek-v4.1-flash;provider=openai";
          SYSTEM_AGENT = "default=openai/deepseek-v4.1-flash";
          VLLM_API_KEY = "none";
          VLLM_PROXY_URL = "http://127.0.0.1:${toString ports.llm}/v1";
          VLLM_MODEL_LIST = "-all,+qwen3.8-27b";
          # The MCP connector, the embedder, and the local chat fallback all
          # live on loopback; the server-side SSRF guard must allow that.
          SSRF_ALLOW_PRIVATE_IP_ADDRESS = "1";
          TELEMETRY_DISABLED = "1";
        };
        environmentFiles = [ "${runtimeDir}/env" ];
      };
    };

    systemd.services.podman-rustfs = {
      requires = [ "lobechat-secrets.service" ];
      after = [ "lobechat-secrets.service" ];
      path = [ pkgs.coreutils ];
      preStart = "${rustfsEnvScript}";
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "30m";
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
    };

    systemd.services.podman-lobechat = {
      requires = [
        "lobechat-secrets.service"
        "lobechat-db-init.service"
        "lobechat-s3-bucket.service"
      ];
      wants = [
        "podman-rustfs.service"
        "memory-llm-proxy.service"
        "llama-cpp-embed.service"
      ];
      after = [
        "lobechat-secrets.service"
        "lobechat-db-init.service"
        "lobechat-s3-bucket.service"
        "podman-rustfs.service"
        "memory-llm-proxy.service"
        "llama-cpp-embed.service"
      ];
      path = [ pkgs.coreutils ];
      preStart = "${lobechatEnvScript}";
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        # A first start runs the whole schema migration before Next answers.
        TimeoutStartSec = lib.mkForce "30m";
        ExecStartPost = "${readinessScript}";
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
    };
  };
}
