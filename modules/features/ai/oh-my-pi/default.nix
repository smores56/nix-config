{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  cfg = config.dotfiles.ohMyPi;
  mcpServers = config.dotfiles.ai.mcpServers;
  workModels = config.dotfiles.workModels;
  cfEnabled = cfg.cloudflareWorkersAi.enable;
  inherit (aiProviders)
    cloudflare
    neuralwatt
    deepseek
    smortress
    codex
    ;
  cfProviderId = cloudflare.providerId;

  # Three-tier model hierarchy. Smoreswork uses Cloudflare Workers AI as the
  # primary provider with Codex models left as backup options. Personal hosts use
  # Neuralwatt GLM-5.2 / Qwen3.5-397B / Qwen3.6-35B and never include Codex.
  tierModels =
    if cfEnabled then
      {
        strong = cloudflare.roles.strong;
        mid = cloudflare.roles.medium;
        weak = cloudflare.roles.weak;
      }
    else if workModels then
      {
        strong = codex.models.gpt55Xhigh;
        mid = codex.models.gpt54;
        weak = codex.models.gpt54Mini;
      }
    else
      {
        strong = "${neuralwatt.providerId}/${neuralwatt.models.glm52.id}";
        mid = "${neuralwatt.providerId}/${neuralwatt.models.qwen35.id}";
        weak = "${neuralwatt.providerId}/${neuralwatt.models.qwen36.id}";
      };

  # Strong: default + plan + slow. Mid: task subagents. Weak: smol/vision and
  # other utility roles. gpt-oss-20b is the weak tier — glm-4.7-flash stalls on
  # CF (HTTP 200, zero-byte body), so gpt-oss-20b (same family, lower latency)
  # backs the cheap/utility roles instead.
  modelRoles = {
    default = tierModels.strong;
    plan = tierModels.strong;
    slow = tierModels.strong;
    task = tierModels.mid;
    smol = tierModels.weak;
    vision = tierModels.weak;
    designer = tierModels.weak;
    commit = tierModels.weak;
    title = tierModels.weak;
  };

  # Provider priority: primary tier provider first, then backups for failover.
  modelProviderOrder =
    if workModels then
      lib.optionals cfEnabled [ cfProviderId ] ++ lib.optionals cfg.codex.enable [ "openai-codex" ]
    else
      [
        neuralwatt.providerId
        deepseek.providerId
        smortress.providerId
      ];

  modelsConfig =
    if workModels then
      lib.optionalAttrs cfEnabled {
        providers.${cfProviderId} = {
          # omp takes provider `baseUrl` literally — no ${VAR} expansion
          # (unlike maki's dynamicBaseUrl), and only `apiKey`/`headers` get
          # env-name/`!cmd` resolution. So the account id can't be a runtime
          # env var in the URL. Emit a @CLOUDFLARE_ACCOUNT_ID@ placeholder and
          # substitute it from the activation env when models.yml is written
          # (enforceOmpModels below) — keeps the id out of the Nix store.
          baseUrl = cloudflare.ompBaseUrl;
          apiKey = cloudflare.keyEnv;
          api = "openai-completions";
          auth = "apiKey";
          models = cloudflare.ompModelsList;
        };
      }
    else
      {
        providers = {
          ${smortress.providerId} = {
            baseUrl = smortress.baseUrl;
            api = "openai-completions";
            auth = "none";
            models = smortress.ompModelsList;
          };
          ${deepseek.providerId} = {
            baseUrl = deepseek.baseUrl;
            apiKey = "DEEPSEEK_API_KEY";
            api = "openai-completions";
            auth = "apiKey";
            models = deepseek.ompModelsList;
          };
          ${neuralwatt.providerId} = {
            baseUrl = neuralwatt.baseUrl;
            apiKey = "NEURALWATT_API_KEY";
            api = "openai-completions";
            auth = "apiKey";
            models = neuralwatt.ompModelsList;
          };
        };
      };

  ompConfig = {
    inherit modelRoles;
    display = {
      showTokenUsage = true;
      shimmer = "classic";
    };
    hideThinkingBlock = false;
    memory = {
      backend = "off";
    };
    exa = {
      enableResearcher = false;
    };
    # Pin the advisor runtime off. It's off by default, but declaring it here
    # re-enforces the disable on every switch so an in-app toggle can't persist.
    advisor = {
      enabled = false;
    };
    compaction = {
      strategy = "context-full";
      keepRecentTokens = if workModels then 20000 else cfg.compaction.keepRecentTokens;
      enabled = true;
      reserveTokens = if workModels then 16384 else cfg.compaction.reserveTokens;
      autoContinue = cfg.compaction.autoContinue;
      idleEnabled = true;
      idleThresholdTokens = 200000;
      idleTimeoutSeconds = 300;
      handoffSaveToDisk = true;
    };
    steeringMode = "one-at-a-time";
    tools = {
      discoveryMode = "all";
    }
    // lib.optionalAttrs workModels {
      artifactSpillThreshold = 30;
      artifactTailBytes = 10;
      artifactHeadBytes = 10;
      artifactTailLines = 250;
      outputMaxColumns = 512;
    };
    inherit modelProviderOrder;
    symbolPreset = "nerd";
    task = {
      showResolvedModelBadge = true;
      isolation = {
        mode = "auto";
      };
      eager = if workModels then "preferred" else true;
    }
    // lib.optionalAttrs workModels {
      softRequestBudget = 40;
      maxRecursionDepth = 1;
    };
    stt = {
      enabled = true;
    };
    collapseChangelog = true;
    tui = {
      textSizing = true;
    };
    readLineNumbers = true;
    lsp = {
      formatOnWrite = true;
      diagnosticsOnEdit = true;
    };
    bashInterceptor = {
      enabled = true;
    };
    renderMermaid = {
      enabled = true;
    };
    checkpoint = {
      enabled = true;
    };
    github = {
      enabled = true;
    };
    async = {
      enabled = true;
    };
    bash = {
      autoBackground = {
        enabled = true;
      };
    };
    mcp = {
      discoveryMode = true;
    };
    secrets = {
      enabled = true;
    };
  }
  // lib.optionalAttrs workModels {
    enabledModels =
      lib.optionals cfEnabled [
        cloudflare.roles.strong
        cloudflare.roles.medium
        cloudflare.roles.weak
      ]
      ++ lib.optionals cfg.codex.enable [
        codex.models.gpt55
        codex.models.gpt54
        codex.models.gpt54Mini
      ];
    defaultThinkingLevel = "medium";
    read = {
      defaultLimit = 200;
    };
  };

  ompPackage = "@oh-my-pi/pi-coding-agent";
in
{
  options.dotfiles.ohMyPi = {
    compaction = {
      reserveTokens = lib.mkOption {
        type = lib.types.int;
        default = 32768;
        description = "Token budget reserved for agent output after compaction.";
      };
      keepRecentTokens = lib.mkOption {
        type = lib.types.int;
        default = 48000;
        description = "Number of recent tokens preserved during compaction.";
      };
      autoContinue = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically continue after compaction instead of prompting.";
      };
    };

    cloudflareWorkersAi.enable = lib.mkEnableOption "Cloudflare Workers AI as the primary oh-my-pi provider";

    codex = {
      enable = lib.mkEnableOption "OpenAI Codex OAuth credentials for oh-my-pi";
    };
  };

  config = {
    # `config.yml` is omp-owned and mutable (so omp's Settings writer —
    # settings.ts:#saveNow, which reads-modifies-writes via Bun.write + YAML
    # stringify on every in-app setting toggle — actually works, instead of
    # hitting /nix/store EROFS on a symlink). Nix still *enforces* its
    # declared `ompConfig` keys every activation via a `yq` deep-merge
    # (`. * $nix`): Nix-declared values win, omp/runtime-only keys survive.
    # Edit at runtime with `yq` (YAML-native jq, added to home.packages
    # below) — `jq` breaks once omp rewrites the file as YAML.
    # `models.yml` is Nix-owned (omp only reads it, never writes), so unlike
    # config.yml it's regenerated fresh every switch rather than deep-merged.
    # It must be activation-written (not a read-only home.file symlink) because
    # the Cloudflare account id is substituted from the env at write time —
    # keeping it out of the Nix store. See the baseUrl placeholder above.
    home.activation.enforceOmpModels = {
      after = [ "linkGeneration" ];
      before = [ "installOmpCli" ];
      data =
        let
          modelsTemplate = pkgs.writeText "omp-models-nix.json" (builtins.toJSON modelsConfig);
        in
        ''
          MODELS="$HOME/.omp/agent/models.yml"
          TEMPLATE="${modelsTemplate}"
          ACCT="''${CLOUDFLARE_ACCOUNT_ID:-}"

          mkdir -p "$(dirname "$MODELS")"

          # Drop a stale Nix-managed symlink from before models.yml became
          # activation-written, so the real file can replace it.
          if [ -L "$MODELS" ]; then
            rm -f "$MODELS"
          fi

          if [ -n "$ACCT" ]; then
            # Substitute the @CLOUDFLARE_ACCOUNT_ID@ placeholder from the
            # activation env (precedent: smolvm.nix reads the same var here).
            # Regenerates every switch so Nix-side model changes land too.
            content="$(<"$TEMPLATE")"
            printf '%s' "''${content//@CLOUDFLARE_ACCOUNT_ID@/$ACCT}" > "$MODELS"
          elif [ ! -e "$MODELS" ]; then
            # No env var and no prior file: seed the template verbatim. The
            # Cloudflare provider will 404 until the env var is present (same
            # failure mode as a missing CLOUDFLARE_API_KEY). Don't clobber an
            # existing file — a switch without the env var must not regress a
            # working setup.
            cp -f "$TEMPLATE" "$MODELS"
            echo "[oh-my-pi] CLOUDFLARE_ACCOUNT_ID unset; Cloudflare models will 404 until it is in the environment" >&2
          fi
        '';
    };
    home.file.".omp/agent/mcp.json" = lib.mkIf (mcpServers != { }) {
      force = true;
      text = builtins.toJSON { inherit mcpServers; };
    };

    home.activation.enforceOmpConfig = {
      after = [ "linkGeneration" ];
      before = [ "installOmpCli" ];
      data =
        let
          ompConfigJson = builtins.toJSON ompConfig;
          nixConfigYaml = pkgs.writeText "omp-config-nix.yml" ompConfigJson;
        in
        ''
          export PATH="${pkgs.yq}/bin:$PATH"
          CONFIG="$HOME/.omp/agent/config.yml"
          NIX_CONFIG="${nixConfigYaml}"

          mkdir -p "$(dirname "$CONFIG")"

          # If config.yml is missing or still a Nix-managed symlink into the
          # store, seed it fresh from the Nix-declared config. From here on omp
          # owns the real file.
          if [ ! -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
            echo "[oh-my-pi] Seeding $CONFIG from Nix"
            rm -f "$CONFIG"
            yq -y '.' "$NIX_CONFIG" > "$CONFIG"
            exit 0
          fi

          # Otherwise: omp already owns the file. Deep-merge the Nix-declared
          # config on top so declared keys are re-enforced on every switch,
          # while runtime-only keys (auth tokens captured at runtime, etc.)
          # survive. `. * $nix` is a shallow-on-arrays / deep-on-objects merge:
          # arrays in Nix replace runtime arrays, objects merge recursively.
          # Mnemopi stays deleted because memory is disabled here.
          echo "[oh-my-pi] Re-enforcing Nix-declared config onto $CONFIG"
          tmp="$(mktemp "''${TMPDIR:-/tmp}/omp-config.XXXXXX.yml")"
          if yq -y --slurpfile nix "$NIX_CONFIG" '. * $nix[0] | del(.mnemopi)' "$CONFIG" > "$tmp"; then
            mv -f "$tmp" "$CONFIG"
          else
            echo "[oh-my-pi] yq merge failed, leaving $CONFIG untouched" >&2
            rm -f "$tmp"
          fi
        '';
    };

    # `spawn_session` omp tool, mirroring maki's lua tool
    # (modules/features/ai/maki/lua/spawn_session.lua) on omp's native
    # extension surface. omp auto-loads ~/.omp/agent/extensions/<dir>/index.ts,
    # and ompConfig's `tools.discoveryMode = "all"` force-includes the tool —
    # no build/bun install step (imports resolve against omp's host bundle).
    home.file.".omp/agent/extensions/spawn_session/index.ts" = {
      force = true;
      source = ./extensions/spawn_session/index.ts;
    };

    home.activation.installOmpCli = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp already installed"
        elif ! command -v bun >/dev/null 2>&1; then
          echo "[oh-my-pi] bun not found in PATH, cannot install ${ompPackage}" >&2
        else
          echo "[oh-my-pi] Installing ${ompPackage} globally with bun"
          if ! bun add -g ${ompPackage}; then
            echo "[oh-my-pi] Failed to install ${ompPackage}; OMP plugin/config commands will be skipped" >&2
          fi
        fi
      '';
    };

    home.activation.configureOmpCodex = lib.mkIf (workModels && cfg.codex.enable) {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        export PATH="$HOME/.bun/bin:$HOME/.cache/.bun/bin:$PATH"

        if ! command -v omp >/dev/null 2>&1; then
          echo "[oh-my-pi] omp not found in PATH, skipping Codex OAuth import"
        else
          AUTH_FILE="$HOME/.codex/auth.json"
          if [ ! -r "$AUTH_FILE" ]; then
            echo "[oh-my-pi] No Codex credentials at $AUTH_FILE, skipping Codex OAuth import"
          elif ! ${pkgs.jq}/bin/jq -e '.tokens.access_token and .tokens.refresh_token' "$AUTH_FILE" >/dev/null 2>&1; then
            echo "[oh-my-pi] Codex credentials are missing OAuth token fields, skipping Codex OAuth import"
          else
            should_import=1
            AGENT_DB="$HOME/.omp/agent/agent.db"
            if [ -r "$AGENT_DB" ]; then
              active_count="$(${pkgs.sqlite}/bin/sqlite3 "$AGENT_DB" "select count(*) from auth_credentials where provider = 'openai-codex' and disabled_cause is null;" 2>/dev/null || echo 0)"
              case "$active_count" in
                0|"") ;;
                *)
                  echo "[oh-my-pi] Codex credentials already present, skipping Codex OAuth import"
                  should_import=0
                  ;;
              esac
            fi

            if [ "$should_import" = 1 ]; then
              expired="$(${pkgs.jq}/bin/jq -r '.tokens.access_token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | .exp | todateiso8601' "$AUTH_FILE" 2>/dev/null || true)"
              if [ -z "$expired" ]; then
                echo "[oh-my-pi] Could not derive Codex token expiry, skipping Codex OAuth import" >&2
              else
                tmp="$(${pkgs.coreutils}/bin/mktemp "''${TMPDIR:-/tmp}/omp-codex-auth.XXXXXX.json")"
                cleanup() {
                  rm -f "$tmp"
                }
                trap cleanup EXIT

                ${pkgs.jq}/bin/jq --arg expired "$expired" '{
                  type: "openai-codex",
                  access_token: .tokens.access_token,
                  refresh_token: .tokens.refresh_token,
                  account_id: .tokens.account_id,
                  expired: $expired
                }' "$AUTH_FILE" > "$tmp"
                chmod 600 "$tmp" 2>/dev/null || true

                if omp auth-broker import "$tmp" --provider openai-codex >/dev/null 2>&1; then
                  echo "[oh-my-pi] Codex OAuth credentials imported for openai-codex models"
                else
                  echo "[oh-my-pi] Failed to import Codex OAuth credentials into OMP"
                fi
              fi
            fi
          fi
        fi
      '';
    };

    home.packages = [ pkgs.yq ];
  };
}
