# The ingest plane (smores56/sdlc#588, part of #509): five Firecracker microVMs, one per source,
# each with a single tap, a read-only secret volume and a vsock channel to a host writer. All
# egress leaves through the host proxy and resolver on the tap's host address; the host writer
# age-encrypts each batch to Kanbei's published recipient and drops it into the read-only inbox
# share. Behind `ingestVm.enable` because the writer needs the Kanbei guest's key.
#
# Facts and policy (allowlists, windows, chains) live in `modules/lib/ingest-vm.nix`; this file
# is the host/guest rendering and the host plumbing.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.ingestVm;
  ingest = import ../lib/ingest-vm.nix { inherit lib; };
  inherit (ingest)
    constants
    sources
    sourceIds
    firewallTable
    firewallUp
    ;

  hardening = import ../lib/hardening.nix;

  # One directory of plain stdlib Python; every service imports `policy` from beside itself.
  ingestTools = pkgs.runCommand "kanbei-ingest-tools" { } ''
    mkdir -p $out/lib/kanbei-ingest
    cp ${../lib/ingest}/*.py $out/lib/kanbei-ingest/
  '';

  mkTool =
    name: script: extraInputs: args:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.python3
        pkgs.coreutils
        pkgs.age
      ]
      ++ extraInputs;
      text = ''
        exec ${pkgs.python3}/bin/python3 ${ingestTools}/lib/kanbei-ingest/${script}.py ${args} "$@"
      '';
    };

  ingestWriter = mkTool "ingest-writer" "writer" [ ] "";
  ingestAgeKey = mkTool "ingest-age-key" "age_key" [ ] "";
  ingestProxy = mkTool "ingest-proxy" "proxy" [ ] "";
  ingestResolver = mkTool "ingest-resolver" "resolver" [ ] "";
  ingestHeartbeat = mkTool "ingest-heartbeat" "heartbeat" [ ] "";
  ingestDigest = mkTool "ingest-digest" "digest" [ ] "";
  tutaSession = mkTool "tuta-session" "tuta_session" [ ] "";
  tutaMail = mkTool "ingest-tuta-mail" "tuta_mail" [ ] "";
  tutaIcs = mkTool "ingest-tuta-ics" "tuta_ics" [ ] "";
  financeTool = mkTool "ingest-finance" "finance" [ ] "";
  plaidTool = mkTool "ingest-finance-plaid" "plaid" [ ] "";
  braveHistory = mkTool "ingest-brave-history" "brave_history" [ ] "";
  braveSync = mkTool "ingest-brave-sync" "brave_sync" [ ] "";
  immichTool = mkTool "ingest-immich" "immich" [ ] "";

  # The search guest's stdlib Python: the gate ladder, the vsock service, the host relay.
  # One directory so `searchd` imports its siblings exactly like the ingest tools do.
  searchTools = pkgs.runCommand "kanbei-search-tools" { } ''
    mkdir -p $out/lib/kanbei-search
    cp ${../lib/search}/*.py $out/lib/kanbei-search/
  '';

  searchRelay = pkgs.writeShellApplication {
    name = "search-relay";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${searchTools}/lib/kanbei-search/search_relay.py "$@"
    '';
  };

  # CPU-only llama.cpp for the Judge lane. The CUDA fork in ../lib/llama-cpp-models.nix
  # is for the 3090; the search guest has no GPU and must not pull CUDA into its closure.
  searchLlamaCpp = pkgs.llama-cpp.override { cudaSupport = false; };

  # The Guardian weights are data, like Kanbei's models: fetched by the operator,
  # hash-checked here, and staged as a read-only block device (#594).
  searchModelManifest = builtins.fromJSON (builtins.readFile ../lib/search-models.json);
  searchModel = searchModelManifest.models.guardian;
  searchModelSource = "${searchModelManifest.destination}/${searchModel.file}";
  searchModelImageDir = "/var/lib/microvms/search-model";
  searchModelImage = "${searchModelImageDir}/guardian.img";
  # The guest root is tmpfs, so the limiter lives on a small writable volume that
  # survives a guest restart instead of a file in the ephemeral root.
  searchStateImageDir = "/var/lib/microvms/search-state";
  searchStateImage = "${searchStateImageDir}/state.img";
  searchGuestModelDir = "/run/search-model";
  searchGuestStateDir = "/var/lib/search";
  searchQueryPort = sources.search.queryPort;
  searchRelayPort = constants.searchQueryPort;
  searchUds = "/var/lib/microvms/kanbei/notify.vsock_${toString searchRelayPort}";

  searchGuestConfig = {
    version = 1;
    gates = {
      max_query_chars = cfg.searchMaxQueryChars;
      per_minute = cfg.searchPerMinute;
      daily_budget = cfg.searchDailyBudget;
    };
    judge = {
      url = "http://127.0.0.1:8091/completion";
      timeout_s = cfg.searchJudgeTimeoutSeconds;
    };
    search = {
      url = "https://api.search.tinyfish.ai/";
      secret = "/run/ingest-secret/env";
      timeout_s = 15;
    };
    results = {
      max_results = 5;
      max_bytes = 4096;
    };
    state = "/var/lib/search/limits.json";
    # Query logs stay on the tmpfs guest root and reach the root-only host journal
    # through the console; only the counters take the writable volume.
    log = "/var/log/search/search.log";
  };

  kanbeiLogs = pkgs.writeShellApplication {
    name = "kanbei-logs";
    runtimeInputs = [
      pkgs.python3
      pkgs.systemd
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../lib/ingest/kanbei_logs.py} "$@"
    '';
  };

  kanbeiIngestVerify = pkgs.writeShellApplication {
    name = "kanbei-ingest-verify";
    runtimeInputs = [
      pkgs.python3
      pkgs.age
      pkgs.systemd
      pkgs.iptables
      pkgs.iproute2
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.curl
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../lib/ingest/verify.py} "$@"
    '';
  };

  # Kanbei's vsock port is host-initiated lookups inverted: the guest dials host CID 2, so
  # Firecracker accepts on `<uds>_<port>` beside its own control socket.
  kanbeiUds = "/var/lib/microvms/kanbei/notify.vsock_${toString constants.ageKeyPort}";
  recipientFile = "${constants.stateRoot}/age-recipient";
  # The cluster CronJob's share and the one file the host writer watches.
  digestShare = "/var/lib/data/cluster-digest";
  digestFile = "${digestShare}/latest.json";
  digestWindowSeconds = ingest.hostSources.cluster-digest.windowSeconds;

  # TutaBridge's loopback session and cache, all tmpfs in the guest and seeded
  # from the read-only secret device at every boot.
  tutaRoot = "/var/lib/tutabridge";
  tutaBridgeEnv = {
    HOME = tutaRoot;
    XDG_CONFIG_HOME = "${tutaRoot}/config";
    XDG_CACHE_HOME = "${tutaRoot}/cache";
    GNUPGHOME = "${tutaRoot}/gnupg";
    PASSWORD_STORE_DIR = "${tutaRoot}/pass";
    PASSWORD_STORE_GPG_OPTS = "--batch --pinentry-mode error";
    TUTABRIDGE_RUNTIME_DIR = "/run/tutabridge";
  };

  # Every tap address and state path is derived once, in the shared table.
  # The Plaid fallback is off by default; enabling it is the only way
  # production.plaid.com enters the finance guest's allowlist (#590).
  effectiveSources = sources // {
    finance = sources.finance // {
      allow = ingest.financeAllow cfg.financePlaid.enable;
    };
  };
  policy = ingest.mkPolicy effectiveSources;

  # Brave (#591): the profile is seeded with `--password-store=basic`, so the
  # fixed OSCrypt key opens the planted `brave_sync.v2.seed`. Chromium takes the
  # proxy from a flag; the resolver allowlist still bounds every other name.
  braveFacts = ingest.factsFor "brave";
  braveProxy = "http://${braveFacts.hostAddr}:${toString constants.proxyPort}";
  braveHome = "/var/lib/brave";
  braveProfile = "${braveHome}/profile";
  braveSyncPull = pkgs.writeShellScript "brave-sync-pull" ''
    set -u
    export HOME=${braveHome}
    export XDG_CONFIG_HOME=${braveHome}/config
    export XDG_CACHE_HOME=${braveHome}/cache
    code=0
    ${pkgs.coreutils}/bin/timeout --signal=TERM 180 ${pkgs.brave}/bin/brave \
      --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
      --password-store=basic --user-data-dir=${braveProfile} \
      --proxy-server=${braveProxy} --no-first-run --no-default-browser-check \
      about:blank || code=$?
    # 124/137: the bounded pull was terminated on purpose.
    if [ "$code" -ne 0 ] && [ "$code" -ne 124 ] && [ "$code" -ne 137 ]; then
      exit "$code"
    fi
  '';
  braveJoinScript = pkgs.writeShellScript "brave-sync-join" ''
    set -eu
    export HOME=${braveHome}
    export XDG_CONFIG_HOME=${braveHome}/config
    export XDG_CACHE_HOME=${braveHome}/cache
    export DISPLAY=:99
    ${pkgs.xvfb}/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
    xvfb=$!
    trap 'kill "$xvfb" 2>/dev/null || true' EXIT
    sleep 2
    # If the owner staged the 25-word code, type it into the setup page.
    if [ -s /run/brave/sync-code ]; then
      (
        sleep 12
        ${pkgs.xdotool}/bin/xdotool search --sync --onlyvisible --name Brave \
          windowactivate --sync type --delay 80 "$(${pkgs.coreutils}/bin/cat /run/brave/sync-code)" || true
      ) &
    fi
    ${pkgs.brave}/bin/brave \
      --user-data-dir=${braveProfile} --password-store=basic --no-sandbox \
      --disable-gpu --proxy-server=${braveProxy} --no-first-run \
      "brave://settings/braveSync/setup" || true
  '';

  # The guest side: one tap, one secret volume, vsock, and no route other than the host.
  # The search guest adds a read-only Guardian model and a writable limiter volume.
  volumesFor =
    id:
    [
      {
        image = "/var/lib/microvms/ingest-secrets/${id}.img";
        mountPoint = "/run/ingest-secret";
        fsType = "ext4";
        readOnly = true;
        autoCreate = false;
        size = 4;
      }
    ]
    ++ lib.optional (id == "search") {
      image = searchModelImage;
      mountPoint = searchGuestModelDir;
      fsType = "ext4";
      readOnly = true;
      autoCreate = false;
      # The host unit sizes the image from the manifest; the value keeps eval complete.
      size = 1536;
    }
    ++ lib.optional (id == "search") {
      image = searchStateImage;
      mountPoint = searchGuestStateDir;
      fsType = "ext4";
      readOnly = false;
      autoCreate = false;
      # The host unit builds the image; the size keeps the option complete for eval.
      size = 8;
    };

  guestFor =
    id:
    let
      s = sources.${id};
      f = ingest.factsFor id;
      emitter = pkgs.writeShellApplication {
        name = "ingest-emit";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec ${pkgs.python3}/bin/python3 ${ingestTools}/lib/kanbei-ingest/guest_emit.py "$@"
        '';
      };
      proxyEnv = {
        HTTP_PROXY = "http://${f.hostAddr}:${toString constants.proxyPort}";
        HTTPS_PROXY = "http://${f.hostAddr}:${toString constants.proxyPort}";
        ALL_PROXY = "http://${f.hostAddr}:${toString constants.proxyPort}";
        http_proxy = "http://${f.hostAddr}:${toString constants.proxyPort}";
        https_proxy = "http://${f.hostAddr}:${toString constants.proxyPort}";
        no_proxy = "localhost,127.0.0.1";
      };
      # Brave reads the proxy from its own flag, not the environment. The
      # resolver allowlist and the tap firewall still bound every other name.
    in
    lib.mkMerge [
      {
        microvm = {
          hypervisor = "firecracker";
          # Mandatory for Firecracker; inside the microvm user's 0775 state dir so it can bind.
          socket = "${f.vmStateDir}/firecracker.sock";
          inherit (s) vcpu mem;
          # The store is a read-only squashfs disk, never a share: Firecracker has no shares.
          registerClosure = false;
          interfaces = [
            {
              type = "tap";
              id = f.tap;
              inherit (f) mac;
            }
          ];
          vsock.cid = s.vsockCid;
          # Read-only block devices. The store disk takes vda; the secret image is vdb and
          # (search only) the Guardian model is vdc.
          volumes = volumesFor id;
        };

        networking = {
          hostName = s.guest;
          useNetworkd = true;
          nameservers = [ f.hostAddr ];
          # The guest firewall is iptables; the host's is too (nftables stays off host-wide).
          nftables.enable = false;
          firewall = {
            enable = true;
            extraCommands = ''
              iptables -w -A OUTPUT -o lo -j ACCEPT
              iptables -w -A OUTPUT -d ${f.hostAddr} -p tcp --dport ${toString constants.proxyPort} -j ACCEPT
              iptables -w -A OUTPUT -d ${f.hostAddr} -p udp --dport ${toString constants.dnsPort} -j ACCEPT
              iptables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
              iptables -w -A OUTPUT -j REJECT
            '';
          };
        };

        systemd.network.networks."10-tap" = {
          matchConfig.MACAddress = f.mac;
          address = [ "${f.guestAddr}/30" ];
          routes = [ { Gateway = f.hostAddr; } ];
          networkConfig = {
            IPv6AcceptRA = false;
            DNS = [ f.hostAddr ];
          };
          linkConfig.RequiredForOnline = "routable";
        };
        boot.kernelModules = [
          "vsock"
          "vmw_vsock_virtio_transport"
        ];
        boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
        services.timesyncd.enable = false;
        environment.variables = proxyEnv;

        systemd.tmpfiles.rules = [
          "d /var/lib/ingest 0700 root root -"
          "d /var/lib/ingest/outbox 0700 root root -"
          "d /var/lib/ingest/sent 0700 root root -"
          "d /var/lib/ingest/rejected 0700 root root -"
          "d /run/ingest-secret 0555 root root -"
        ];

        systemd.services.ingest-emit = {
          description = "Ship ${id} NDJSON batches to the host writer over vsock";
          wantedBy = [ "multi-user.target" ];
          requires = [ "run-ingest-secret.mount" ];
          after = [
            "run-ingest-secret.mount"
            "systemd-tmpfiles-setup.service"
          ];
          restartIfChanged = false;
          environment = proxyEnv;
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            UMask = "0077";
            ExecStart = "${emitter}/bin/ingest-emit --source ${id} --port ${toString s.vsockPort} --outbox /var/lib/ingest/outbox --secret /run/ingest-secret/env";
          };
        };

        system.stateVersion = "26.05";
      }
      (lib.mkIf (id == "tuta") {
        environment.systemPackages = [
          pkgs.gnupg
          pkgs.pass
          pkgs.tutabridge
        ];
        systemd.tmpfiles.rules = [
          "d ${tutaRoot} 0700 root root -"
          "d ${tutaRoot}/config 0700 root root -"
          "d ${tutaRoot}/cache 0700 root root -"
          "d ${tutaRoot}/gnupg 0700 root root -"
          "d ${tutaRoot}/pass 0700 root root -"
          "d ${tutaRoot}/calendar 0700 root root -"
          "d /run/tutabridge 0700 root root -"
        ];

        # 1. Seed gnupg/pass/config from the secret image; write the loopback
        #    address and bridge password under /run at 0600. The env file is
        #    parsed by the tool, never by an EnvironmentFile (that would expose
        #    values through `systemctl show`).
        systemd.services.tutabridge-session = {
          description = "Stage the TutaBridge session from the read-only secret device";
          wantedBy = [ "multi-user.target" ];
          requires = [ "run-ingest-secret.mount" ];
          after = [
            "run-ingest-secret.mount"
            "systemd-tmpfiles-setup.service"
          ];
          before = [
            "tutabridge.service"
            "ingest-tuta-mail.service"
          ];
          unitConfig = {
            StartLimitBurst = 5;
            StartLimitIntervalSec = 300;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
            TimeoutStartSec = 120;
            ExecStart = "${tutaSession}/bin/tuta-session --env /run/ingest-secret/env --root ${tutaRoot} --runtime-dir /run/tutabridge --imap-port ${toString constants.tutaBridge.imapPort} --smtp-port ${toString constants.tutaBridge.smtpPort}";
          };
        };

        # 2. The bridge itself. `run --wait` keeps retrying while the session is
        #    rejected; the mail collector reads manifest state, not the exit code.
        systemd.services.tutabridge = {
          description = "TutaBridge IMAP/SMTP bridge on loopback";
          wantedBy = [ "multi-user.target" ];
          requires = [ "tutabridge-session.service" ];
          after = [
            "tutabridge-session.service"
            "network.target"
          ];
          environment = tutaBridgeEnv;
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "10s";
            UMask = "0077";
            TimeoutStopSec = 20;
            # The bridge's own log names folders and the address; keep it root-only
            # and let the collector scan it for Tuta client-version rejections.
            StandardOutput = "append:${tutaRoot}/bridge.log";
            StandardError = "append:${tutaRoot}/bridge.log";
            ExecStartPre = "${pkgs.gnupg}/bin/gpgconf --launch gpg-agent";
            ExecStart = "${pkgs.tutabridge}/bin/tutabridge run --wait";
            # A mailbox keeps its encrypted cache in this tmpfs; cap it so a
            # runaway sync cannot take the guest down.
            MemoryHigh = "180M";
            MemoryMax = "240M";
          };
        };

        # 3. Mail collector: IDLE plus UID SEARCH, one NDJSON batch per chunk.
        systemd.services.ingest-tuta-mail = {
          description = "Collect new Tuta mail and Sent items into the ingest outbox";
          wantedBy = [ "multi-user.target" ];
          requires = [ "tutabridge.service" ];
          after = [
            "tutabridge.service"
            "tutabridge-session.service"
            "ingest-emit.service"
            "systemd-tmpfiles-setup.service"
          ];
          environment = proxyEnv;
          unitConfig = {
            StartLimitBurst = 10;
            StartLimitIntervalSec = 300;
          };
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "15s";
            UMask = "0077";
            TimeoutStopSec = 15;
            ExecStart = "${tutaMail}/bin/ingest-tuta-mail --host ${constants.tutaBridge.bindAddr} --port ${toString constants.tutaBridge.imapPort} --address-file /run/tutabridge/address --password-file /run/tutabridge/bridge-password --outbox /var/lib/ingest/outbox --state ${tutaRoot}/mail-state.json --bridge-log ${tutaRoot}/bridge.log";
          };
        };

        # 4. Calendar: the ICS renderer core runs on a timer. Until the SDK
        #    fetcher builds, it emits a daily `calendar-unavailable` alert so the
        #    gap is visible; a fetcher that writes events.json switches it to
        #    real ICS deltas with no unit change.
        systemd.services.ingest-tuta-ics = {
          description = "Render Tuta calendar changes as ICS batches";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
            TimeoutStartSec = 120;
            ExecStart = "${tutaIcs}/bin/ingest-tuta-ics --binary ${pkgs.tuta-ics}/bin/tuta-ics --events ${tutaRoot}/calendar/events.json --out ${tutaRoot}/calendar/current.ics --state ${tutaRoot}/calendar-state.json --outbox /var/lib/ingest/outbox";
          };
        };
        systemd.timers.ingest-tuta-ics = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*:0/30";
            RandomizedDelaySec = "120";
            Persistent = false;
          };
        };
      })
      (lib.mkIf (id == "finance") {
        # SimpleFIN is one GET per day; Plaid only when the owner enables it.
        systemd.tmpfiles.rules = [ "d /var/lib/finance 0700 root root -" ];
        systemd.services.ingest-finance = {
          description = "Collect SimpleFIN accounts and render hledger journals";
          after = [
            "ingest-emit.service"
            "run-ingest-secret.mount"
            "systemd-tmpfiles-setup.service"
          ];
          requires = [ "run-ingest-secret.mount" ];
          environment = proxyEnv;
          restartIfChanged = false;
          unitConfig = {
            StartLimitBurst = 5;
            StartLimitIntervalSec = 300;
          };
          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
            TimeoutStartSec = 300;
            MemoryHigh = "96M";
            MemoryMax = "160M";
            ExecStart = "${financeTool}/bin/ingest-finance --env /run/ingest-secret/env --outbox /var/lib/ingest/outbox --state /var/lib/finance/state.json";
          };
        };
        systemd.timers.ingest-finance = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 06:17:00";
            RandomizedDelaySec = "1800";
            Persistent = true;
          };
        };
      })
      (lib.mkIf (id == "brave") {
        # Headless Brave joined to the owner's Sync chain. The one headful
        # session is the manual `brave-sync-join` unit; the timer only runs
        # `--headless=new` for a bounded pull and then reads History.
        environment.systemPackages = [
          pkgs.brave
          pkgs.xvfb
          pkgs.xdotool
        ];
        systemd.tmpfiles.rules = [
          "d /var/lib/brave 0700 root root -"
          "d /var/lib/brave/profile 0700 root root -"
          "d /var/lib/brave/work 0700 root root -"
          "d /var/lib/brave/config 0700 root root -"
          "d /var/lib/brave/cache 0700 root root -"
          "d /run/brave 0700 root root -"
        ];
        environment.variables = {
          HOME = "/var/lib/brave";
          XDG_CONFIG_HOME = "/var/lib/brave/config";
          XDG_CACHE_HOME = "/var/lib/brave/cache";
        };

        systemd.services.ingest-brave-sync = {
          description = "Seed the Brave profile and pull the Sync chain headlessly";
          after = [
            "run-ingest-secret.mount"
            "systemd-tmpfiles-setup.service"
          ];
          requires = [ "run-ingest-secret.mount" ];
          restartIfChanged = false;
          unitConfig = {
            StartLimitBurst = 5;
            StartLimitIntervalSec = 300;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = false;
            UMask = "0077";
            TimeoutStartSec = 360;
            MemoryHigh = "640M";
            MemoryMax = "800M";
            ExecStartPre = "${braveSync}/bin/ingest-brave-sync --env /run/ingest-secret/env --prefs ${braveProfile}/Default/Preferences --code-out /run/brave/sync-code";
            ExecStart = braveSyncPull;
          };
        };

        systemd.services.ingest-brave-history = {
          description = "Read new History visits into the ingest outbox";
          wantedBy = [ "multi-user.target" ];
          wants = [ "ingest-brave-sync.service" ];
          after = [
            "ingest-brave-sync.service"
            "ingest-emit.service"
            "systemd-tmpfiles-setup.service"
          ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
            TimeoutStartSec = 300;
            MemoryHigh = "96M";
            MemoryMax = "128M";
            ExecStart = "${braveHistory}/bin/ingest-brave-history --profile ${braveProfile} --state /var/lib/brave/state.json --outbox /var/lib/ingest/outbox --workdir /var/lib/brave/work --lookback-hours 24";
          };
        };
        systemd.timers.ingest-brave-history = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 04:37:00";
            RandomizedDelaySec = "3600";
            Persistent = true;
          };
        };

        # Manually started once (docs/kanbei-ingest-brave.md): a real X window
        # under Xvfb is the only way to drive Brave's Sync setup page. The
        # supported unattended path is the planted `brave_sync.v2.seed`.
        systemd.services.brave-sync-join = {
          description = "One-time Brave Sync chain join under Xvfb (manual)";
          after = [ "run-ingest-secret.mount" ];
          requires = [ "run-ingest-secret.mount" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "infinity";
            MemoryHigh = "640M";
            MemoryMax = "800M";
            ExecStart = braveJoinScript;
          };
        };
      })
      (lib.mkIf (id == "immich") {
        # Metadata only: the client refuses every byte endpoint before dialling.
        systemd.tmpfiles.rules = [ "d /var/lib/immich 0700 root root -" ];
        systemd.services.ingest-immich = {
          description = "Collect Immich asset, EXIF, place, people and album metadata";
          after = [
            "ingest-emit.service"
            "run-ingest-secret.mount"
            "systemd-tmpfiles-setup.service"
          ];
          requires = [ "run-ingest-secret.mount" ];
          environment = proxyEnv;
          restartIfChanged = false;
          unitConfig = {
            StartLimitBurst = 5;
            StartLimitIntervalSec = 300;
          };
          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
            TimeoutStartSec = 300;
            MemoryHigh = "80M";
            MemoryMax = "112M";
            ExecStart = "${immichTool}/bin/ingest-immich --env /run/ingest-secret/env --outbox /var/lib/ingest/outbox --state /var/lib/immich/state.json";
          };
        };
        systemd.timers.ingest-immich = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 03:23:00";
            RandomizedDelaySec = "900";
            Persistent = true;
          };
        };
      })
      (lib.mkIf (id == "search") {
        # The verifier's guest: one deterministic batch and a direct-egress probe. T15 replaces
        # both when the search service ships its own emitter.
        systemd.services.ingest-test-seed = {
          description = "Seed one deterministic batch for kanbei-ingest-verify";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          before = [ "ingest-emit.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            set -eu
            install -d -m 0700 /var/lib/ingest/outbox
            cat > /var/lib/ingest/outbox/000000-test.json <<'EOF'
            {"v":1,"source":"search","kind":"batch","seq":1,"sent_at":"1970-01-01T00:00:00Z","items":[{"probe":"kanbei-ingest-verify"}]}
            EOF
            chmod 0600 /var/lib/ingest/outbox/000000-test.json
          '';
        };

        systemd.services.ingest-egress-probe = {
          description = "Prove the guest cannot reach the internet directly";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -u
            if ${pkgs.curl}/bin/curl --noproxy '*' --silent --show-error --max-time 3 \
                --output /dev/null http://1.1.1.1/ 2>/dev/null; then
              echo "INGEST-EGRESS-REACHED" > /dev/console
              exit 1
            fi
            echo "INGEST-EGRESS-DROPPED" > /dev/console
          '';
        };

        # The query service (#594): DLP -> cap -> rate/budget -> Guardian -> TinyFish.
        # The judge is a loopback llama.cpp server; every stage blocks on failure.
        environment.systemPackages = [
          searchLlamaCpp
          pkgs.curl
        ];
        systemd.tmpfiles.rules = [
          "d /var/log/search 0700 root root -"
          "d /run/search-model 0555 root root -"
        ];
        environment.etc."kanbei-search/search.json" = {
          mode = "0600";
          text = builtins.toJSON searchGuestConfig;
        };

        systemd.services.search-judge = {
          description = "Granite Guardian exfiltration judge on CPU";
          wantedBy = [ "multi-user.target" ];
          requires = [ "run-search-model.mount" ];
          after = [
            "run-search-model.mount"
            "systemd-tmpfiles-setup.service"
          ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "10s";
            UMask = "0077";
            # Weights are mmapped; the caps leave room for the guest userland in 2560 MiB.
            MemoryHigh = "1600M";
            MemoryMax = "2100M";
            ExecStart = "${searchLlamaCpp}/bin/llama-server --model ${searchGuestModelDir}/${searchModel.file} --host 127.0.0.1 --port 8091 --ctx-size 2048 --threads 2 --n-gpu-layers 0 --parallel 1 --no-warmup --no-webui";
            StandardOutput = "append:/var/log/search/judge.log";
            StandardError = "append:/var/log/search/judge.log";
          };
        };

        systemd.services.searchd = {
          description = "Capped search query API on vsock";
          wantedBy = [ "multi-user.target" ];
          requires = [
            "run-ingest-secret.mount"
            "run-search-model.mount"
            "var-lib-search.mount"
          ];
          wants = [ "search-judge.service" ];
          after = [
            "run-ingest-secret.mount"
            "run-search-model.mount"
            "var-lib-search.mount"
            "search-judge.service"
            "systemd-tmpfiles-setup.service"
          ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            UMask = "0077";
            MemoryHigh = "96M";
            MemoryMax = "160M";
            ExecStart = "${pkgs.python3}/bin/python3 ${searchTools}/lib/kanbei-search/searchd.py --config /etc/kanbei-search/search.json --port ${toString searchQueryPort}";
            # The guest journal is not forwarded; the console copy is what reaches the
            # root-only `microvm@search` journal on the host behind `kanbei-logs`.
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
        };
      })
    ];

  prepScript = pkgs.writeShellScript "ingest-vm-prep" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    install -d -m 0700 ${constants.stateRoot}
    install -d -m 0700 ${constants.stateRoot}/state
    install -d -m 0700 ${constants.logDir}
    install -d -m 0755 -o root -g root ${constants.inboxDir}
    # Firecracker runs as microvm:kvm and must read the secret image; the directory stays out
    # of the guest-reachable 0700 state root so the group can traverse it.
    install -d -m 0750 -o root -g kvm /var/lib/microvms/ingest-secrets
  '';

  # The Guardian image is built once from the operator-fetched file and hash-checked
  # against the manifest; an unchanged image is left alone, and a running guest is
  # never replaced underneath.
  searchModelScript = pkgs.writeShellScript "search-vm-model" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.e2fsprogs
      ]
    }
    src=${lib.escapeShellArg searchModelSource}
    image=${lib.escapeShellArg searchModelImage}
    dir=${lib.escapeShellArg searchModelImageDir}
    name=${lib.escapeShellArg searchModel.file}
    want=${searchModel.sha256}
    size=${toString searchModel.size}
    if [ ! -r "$src" ]; then
      echo "search-vm-model: missing $src; fetch it with modules/lib/kanbei-fetch-models.py (docs/manual-steps.md)" >&2
      exit 1
    fi
    actual_size=$(stat -c %s "$src")
    if [ "$actual_size" != "$size" ]; then
      echo "search-vm-model: $src is $actual_size bytes, the manifest says $size" >&2
      exit 1
    fi
    sum="$image.sha256"
    if [ -s "$sum" ] && [ "$(cat "$sum")" = "$want" ] && [ -e "$image" ]; then
      exit 0
    fi
    actual=$(sha256sum "$src" | cut -d' ' -f1)
    if [ "$actual" != "$want" ]; then
      echo "search-vm-model: $src sha256 $actual, the manifest says $want" >&2
      exit 1
    fi
    if ${config.systemd.package}/bin/systemctl is-active --quiet microvm@${sources.search.guest}.service; then
      echo "search-vm-model: refusing to replace the image under a running guest" >&2
      exit 1
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    root="$tmp/root"
    install -d -m 0755 "$root"
    install -m 0444 "$src" "$root/$name"
    truncate -s "$((actual_size + 33554432))" "$tmp/image"
    mkfs.ext4 -q -F -L search-model -d "$root" "$tmp/image"
    install -d -m 0750 -o root -g kvm "$dir"
    install -m 0440 -o root -g kvm "$tmp/image" "$image"
    printf '%s\n' "$want" > "$sum"
    chmod 0400 "$sum"
  '';

  # A tiny writable ext4 image for the limiter. It is created once and never
  # reformatted, so the counters survive a guest restart; deleting the image is
  # the deliberate budget reset.
  searchStateScript = pkgs.writeShellScript "search-vm-state" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.e2fsprogs
      ]
    }
    image=${lib.escapeShellArg searchStateImage}
    dir=${lib.escapeShellArg searchStateImageDir}
    if [ -e "$image" ]; then
      exit 0
    fi
    install -d -m 0750 -o root -g kvm "$dir"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    truncate -s 8M "$tmp/image"
    mkfs.ext4 -q -F -L search-state "$tmp/image"
    install -m 0660 -o root -g kvm "$tmp/image" "$image"
  '';

  secretScript =
    id:
    let
      guest = sources.${id}.guest;
    in
    pkgs.writeShellScript "ingest-vm-secret-${id}" ''
      set -euo pipefail
      export PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.e2fsprogs
        ]
      }
      src=/run/secrets/${id}-env
      image=/var/lib/microvms/ingest-secrets/${id}.img
      sum="$image.sha256"
      if [ ! -r "$src" ]; then
        echo "ingest-vm-secret-${id}: missing $src; stage the ${id} secret (docs/manual-steps.md)" >&2
        exit 1
      fi
      want=$(sha256sum "$src" | cut -d' ' -f1)
      if [ -s "$sum" ] && [ "$(cat "$sum")" = "$want" ] && [ -e "$image" ]; then
        exit 0
      fi
      if ${config.systemd.package}/bin/systemctl is-active --quiet microvm@${guest}.service; then
        echo "ingest-vm-secret-${id}: refusing to replace the image under a running guest" >&2
        exit 1
      fi
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      # mkfs -d copies the directory, so the image lives outside it.
      root="$tmp/root"
      install -d -m 0700 "$root"
      install -m 0400 "$src" "$root/env"
      truncate -s 4M "$tmp/image"
      mkfs.ext4 -q -F -L "ingest-${id}-secret" -d "$root" "$tmp/image"
      install -m 0440 -o root -g kvm "$tmp/image" "$image"
      printf '%s\n' "$want" > "$sum"
      chmod 0400 "$sum"
    '';

  netScript =
    id:
    let
      f = ingest.factsFor id;
    in
    pkgs.writeShellScript "ingest-vm-net-${id}" ''
      set -eu
      ${pkgs.procps}/bin/sysctl -qw net.ipv6.conf.${f.tap}.disable_ipv6=1
      ${pkgs.iproute2}/bin/ip addr replace ${f.hostAddr}/30 dev ${f.tap}
      ${pkgs.iproute2}/bin/ip link set ${f.tap} up
    '';

  serviceSandbox = hardening // {
    ReadWritePaths = [
      constants.inboxDir
      constants.stateRoot
      constants.logDir
    ];
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_VSOCK"
    ];
    RestrictSUIDSGID = true;
    LockPersonality = true;
  };
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  options.ingestVm.enable = lib.mkEnableOption "the Firecracker ingest plane and its host writer, proxy and resolver";

  options.ingestVm.financePlaid.enable = lib.mkEnableOption "the Plaid fallback for institutions SimpleFIN cannot reach";

  options.ingestVm.searchMaxQueryChars = lib.mkOption {
    type = lib.types.ints.between 1 320;
    default = 100;
    description = ''
      Hard cap on a normalised search query, in characters. The gate's code-level
      ceiling is 320 (`gates.MAX_QUERY_CHARS_HARD`); the default is ~100.
    '';
  };

  options.ingestVm.searchPerMinute = lib.mkOption {
    type = lib.types.ints.between 1 10000;
    default = 20;
    description = "Sliding per-minute limit on admitted search queries, persisted in the guest.";
  };

  options.ingestVm.searchDailyBudget = lib.mkOption {
    type = lib.types.ints.between 1 1000000;
    default = 300;
    description = "UTC-day budget for admitted search queries, persisted in the guest.";
  };

  options.ingestVm.searchJudgeTimeoutSeconds = lib.mkOption {
    type = lib.types.ints.between 1 120;
    default = 20;
    description = "Timeout for one Granite Guardian call; a timeout blocks the query.";
  };

  config = lib.mkIf cfg.enable {
    microvm.vms = builtins.listToAttrs (
      map (id: {
        name = sources.${id}.guest;
        value = {
          autostart = true;
          restartIfChanged = false;
          config = guestFor id;
        };
      }) sourceIds
    );

    # Directories, policy, firewall table and the fixed-address taps.
    systemd.services = lib.mkMerge [
      {
        ingest-vm-prep = {
          description = "Create the ingest plane's root-only state, inbox and policy";
          wantedBy = [ "multi-user.target" ];
          before = [
            "ingest-vm-net-tuta.service"
          ]
          ++ map (id: "microvm@${sources.${id}.guest}.service") sourceIds;
          after = [ "local-fs.target" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = prepScript;
          };
        };

        ingest-age-key = {
          description = "Accept Kanbei's age recipient on the schema-locked vsock port";
          wantedBy = [
            "multi-user.target"
            "microvm@kanbei.service"
          ];
          after = [
            "microvm@kanbei.service"
            "ingest-vm-prep.service"
          ];
          wants = [
            "microvm@kanbei.service"
            "ingest-vm-prep.service"
          ];
          bindsTo = [ "microvm@kanbei.service" ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "2s";
            UMask = "0077";
            ExecStart = "${ingestAgeKey}/bin/ingest-age-key --uds ${kanbeiUds} --out ${recipientFile}";
            StandardOutput = "append:${constants.logDir}/ingest-age-key.log";
            StandardError = "append:${constants.logDir}/ingest-age-key.log";
            ReadWritePaths = [ "/var/lib/microvms/kanbei" ] ++ serviceSandbox.ReadWritePaths;
          };
        };

        ingest-proxy = {
          description = "Hostname/SNI-filtering HTTP(S) proxy for the ingest taps";
          wantedBy = [ "multi-user.target" ];
          after = [
            "ingest-vm-prep.service"
            "network.target"
          ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "3s";
            UMask = "0077";
            ExecStart = "${ingestProxy}/bin/ingest-proxy --policy ${constants.policyFile}";
            StandardOutput = "append:${constants.logDir}/ingest-proxy.log";
            StandardError = "append:${constants.logDir}/ingest-proxy.log";
          };
        };

        ingest-resolver = {
          description = "Allowlist-only DNS responder for the ingest taps";
          wantedBy = [ "multi-user.target" ];
          after = [
            "ingest-vm-prep.service"
            "network.target"
          ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "3s";
            UMask = "0077";
            ExecStart = "${ingestResolver}/bin/ingest-resolver --policy ${constants.policyFile}";
            StandardOutput = "append:${constants.logDir}/ingest-resolver.log";
            StandardError = "append:${constants.logDir}/ingest-resolver.log";
          };
        };

        ingest-heartbeat = {
          description = "Publish ingest freshness to Kanbei and alert on stale sources";
          after = [ "ingest-vm-prep.service" ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "oneshot";
            UMask = "0077";
            ExecStart = "${ingestHeartbeat}/bin/ingest-heartbeat --policy ${constants.policyFile} --state-dir ${constants.stateRoot}/state --inbox ${constants.inboxDir} --recipient-file ${recipientFile} --retain-hours ${toString constants.heartbeatRetainHours}";
            StandardOutput = "append:${constants.logDir}/ingest-heartbeat.log";
            StandardError = "append:${constants.logDir}/ingest-heartbeat.log";
          };
        };

        # The cluster digest is the one host-written source: the platform
        # CronJob writes latest.json into the data share, and this watcher
        # age-encrypts each new `generated_at` into the inbox. It does not bind
        # to microvm@cluster: the writer must survive a cluster restart and just
        # wait for the next document.
        ingest-writer-cluster-digest = {
          description = "Age-encrypt the cluster digest into Kanbei's inbox";
          after = [
            "ingest-vm-prep.service"
            "ingest-age-key.service"
          ];
          wants = [
            "ingest-age-key.service"
            "ingest-vm-prep.service"
          ];
          wantedBy = [ "multi-user.target" ];
          onFailure = [ "cloudflare-email@%n.service" ];
          restartIfChanged = false;
          unitConfig = {
            StartLimitBurst = 5;
            StartLimitIntervalSec = 300;
          };
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            UMask = "0077";
            ExecStart = "${ingestDigest}/bin/ingest-digest --source cluster-digest --file ${digestFile} --recipient-file ${recipientFile} --inbox ${constants.inboxDir} --state-dir ${constants.stateRoot}/state --window ${toString digestWindowSeconds} --max-bytes 65536";
            StandardOutput = "append:${constants.logDir}/ingest-writer-cluster-digest.log";
            StandardError = "append:${constants.logDir}/ingest-writer-cluster-digest.log";
          };
        };

        # The search guest's model volume (#594). It is staged before the guest
        # starts and never replaced while it runs.
        search-vm-model = {
          description = "Stage the read-only Granite Guardian model image for the search guest";
          after = [
            "ingest-vm-prep.service"
            "local-fs.target"
          ];
          before = [ "microvm@${sources.search.guest}.service" ];
          requiredBy = [ "microvm@${sources.search.guest}.service" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
            ExecStart = searchModelScript;
          };
        };

        # The limiter volume: created once, never reformatted.
        search-vm-state = {
          description = "Create the search guest's writable limiter image";
          after = [
            "ingest-vm-prep.service"
            "local-fs.target"
          ];
          before = [ "microvm@${sources.search.guest}.service" ];
          requiredBy = [ "microvm@${sources.search.guest}.service" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
            ExecStart = searchStateScript;
          };
        };

        # Kanbei dials host CID 2 : 7101; this listener pipes the connection to the
        # search guest's query port. It carries bytes only and logs metadata.
        search-relay = {
          description = "Pipe Kanbei's vsock search port to the search guest";
          wantedBy = [
            "multi-user.target"
            "microvm@kanbei.service"
          ];
          after = [
            "microvm@kanbei.service"
            "ingest-vm-prep.service"
          ];
          wants = [
            "microvm@kanbei.service"
            "ingest-vm-prep.service"
          ];
          bindsTo = [ "microvm@kanbei.service" ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "2s";
            UMask = "0077";
            ExecStart = "${searchRelay}/bin/search-relay --uds ${searchUds} --vsock /var/lib/microvms/${sources.search.guest}/notify.vsock --port ${toString searchQueryPort} --group kvm";
            StandardOutput = "append:${constants.logDir}/search-relay.log";
            StandardError = "append:${constants.logDir}/search-relay.log";
            ReadWritePaths = [ "/var/lib/microvms/kanbei" ] ++ serviceSandbox.ReadWritePaths;
          };
        };
      }
      (builtins.listToAttrs (
        map (
          id:
          let
            s = sources.${id};
            f = ingest.factsFor id;
          in
          {
            name = "ingest-writer-${id}";
            value = {
              description = "Age-encrypt ${id} ingest batches into Kanbei's inbox";
              after = [
                "microvm@${s.guest}.service"
                "ingest-age-key.service"
                "ingest-vm-prep.service"
              ];
              wantedBy = [
                "multi-user.target"
                "microvm@${s.guest}.service"
              ];
              wants = [
                "microvm@${s.guest}.service"
                "ingest-age-key.service"
                "ingest-vm-prep.service"
              ];
              bindsTo = [ "microvm@${s.guest}.service" ];
              # A rejected batch or a vanished guest fails the unit; the alert path surfaces it.
              onFailure = [ "cloudflare-email@%n.service" ];
              restartIfChanged = false;
              # A rejected batch exits 65; do not hammer the guest or the mail path.
              unitConfig = {
                StartLimitBurst = 5;
                StartLimitIntervalSec = 300;
              };
              serviceConfig = serviceSandbox // {
                Type = "simple";
                Restart = "always";
                RestartSec = "5s";
                UMask = "0077";
                ExecStart = "${ingestWriter}/bin/ingest-writer --policy ${constants.policyFile} --source ${id} --vsock ${f.vmStateDir}/notify.vsock --guest-port ${toString s.vsockPort} --recipient-file ${recipientFile} --inbox ${constants.inboxDir} --state-dir ${constants.stateRoot}/state";
                StandardOutput = "append:${constants.logDir}/ingest-writer-${id}.log";
                StandardError = "append:${constants.logDir}/ingest-writer-${id}.log";
              };
            };
          }
        ) sourceIds
      ))
      (builtins.listToAttrs (
        lib.concatMap (
          id:
          let
            s = sources.${id};
          in
          [
            {
              name = "ingest-vm-secret-${id}";
              value = {
                description = "Stage the ${id} secret block device from /run/secrets/${id}-env";
                after = [ "ingest-vm-prep.service" ];
                before = [ "microvm@${s.guest}.service" ];
                requiredBy = [ "microvm@${s.guest}.service" ];
                restartIfChanged = false;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = secretScript id;
                };
              };
            }
            {
              name = "ingest-vm-net-${id}";
              value = {
                description = "Address the ${s.guest} tap";
                after = [ "microvm-tap-interfaces@${s.guest}.service" ];
                bindsTo = [ "microvm-tap-interfaces@${s.guest}.service" ];
                before = [ "microvm@${s.guest}.service" ];
                requiredBy = [ "microvm@${s.guest}.service" ];
                restartIfChanged = false;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = netScript id;
                };
              };
            }
          ]
        ) sourceIds
      ))
    ];

    environment.etc."kanbei-ingest/policy.json" = {
      mode = "0600";
      text = builtins.toJSON policy;
    };
    # `firewallUp` restores this exact text; the check asserts it is only the generated rules.
    environment.etc."kanbei-ingest/rules.v4" = {
      mode = "0600";
      text = firewallTable;
    };

    systemd.tmpfiles.rules = [
      "d ${constants.stateRoot} 0700 root root -"
      "d ${constants.stateRoot}/state 0700 root root -"
      "d ${constants.logDir} 0700 root root -"
      "d ${constants.inboxDir} 0755 root root -"
      "d /var/lib/microvms/ingest-secrets 0750 root kvm -"
    ];

    networking = {
      networkmanager.unmanaged = map (id: (ingest.factsFor id).tap) sourceIds;
      firewall.enable = true;
      firewall.extraCommands = firewallUp;
    };

    environment.systemPackages = [
      kanbeiLogs
      kanbeiIngestVerify
      ingestWriter
      ingestDigest
      plaidTool
    ];

    assertions = [
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "ingest-vm: per-tap chains are iptables; the host must stay on iptables";
      }
      {
        assertion = config.kanbeiVm.enable or false;
        message = "ingest-vm: the writer encrypts to Kanbei's published key; enable kanbeiVm first";
      }
      {
        assertion = ingest.validateSources effectiveSources == [ ];
        message = "ingest-vm: a configured hostname is outside a source's permit table: ${lib.concatStringsSep "; " (ingest.validateSources effectiveSources)}";
      }
      {
        assertion = ingest.validateHostSources ingest.hostSources == [ ];
        message = "ingest-vm: a host source is misconfigured: ${lib.concatStringsSep "; " (ingest.validateHostSources ingest.hostSources)}";
      }
      {
        assertion = ingest.validateFacts sources == [ ];
        message = "ingest-vm: guest facts collide: ${lib.concatStringsSep "; " (ingest.validateFacts sources)}";
      }
      {
        assertion =
          ingest.validateFirewall {
            tbl = sources;
            rules = firewallTable;
          } == [ ];
        message = "ingest-vm: firewall rules allow more than proxy/resolver on a tap: ${
          lib.concatStringsSep "; " (
            ingest.validateFirewall {
              tbl = sources;
              rules = firewallTable;
            }
          )
        }";
      }
    ]
    ++ lib.concatMap (
      id:
      let
        s = sources.${id};
        guest = config.microvm.vms.${s.guest}.config.config;
        m = guest.microvm;
      in
      [
        {
          assertion = m.hypervisor == "firecracker";
          message = "ingest-vm: ${s.guest} must run on Firecracker";
        }
        {
          assertion =
            m.socket != null
            && m.shares == [ ]
            && m.devices == [ ]
            && builtins.length m.interfaces == 1
            && builtins.length m.volumes == s.volumes
            && lib.all (v: v.readOnly || v.mountPoint == searchGuestStateDir) m.volumes;
          message = "ingest-vm: ${s.guest} needs a socket, one tap and read-only volumes (the search limiter volume is the one writable exception)";
        }
        {
          assertion = m.vsock.cid == s.vsockCid;
          message = "ingest-vm: ${s.guest} vsock cid drifted from the shared table";
        }
        {
          assertion =
            s ? queryPort
            -> (
              guest.systemd.services ? searchd
              && builtins.length m.volumes == 3
              && (lib.elemAt m.volumes 1).image == searchModelImage
              && (lib.elemAt m.volumes 1).mountPoint == searchGuestModelDir
              && (lib.elemAt m.volumes 1).readOnly
              && (lib.elemAt m.volumes 2).image == searchStateImage
              && (lib.elemAt m.volumes 2).mountPoint == searchGuestStateDir
              && !(lib.elemAt m.volumes 2).readOnly
            );
          message = "ingest-vm: the search guest needs the query service, the read-only Guardian model and the writable limiter volume";
        }
        {
          assertion =
            config.systemd.services."ingest-writer-${id}".restartIfChanged == false
            && config.systemd.services."ingest-vm-net-${id}".restartIfChanged == false
            && config.systemd.services."ingest-vm-secret-${id}".restartIfChanged == false
            && config.microvm.vms.${s.guest}.restartIfChanged == false;
          message = "ingest-vm: prep/net/writer and the VM must not restart on a host switch";
        }
      ]
    ) sourceIds
    ++ [
      {
        assertion =
          !lib.any (
            i: lib.elem (ingest.factsFor i).tap (config.networking.nat.internalInterfaces or [ ])
          ) sourceIds;
        message = "ingest-vm: no ingest tap may be NATed; all egress is the host proxy";
      }
      {
        assertion =
          !(config.microvm.vms ? kanbei)
          || lib.all (
            id: (ingest.factsFor id).vsockCid != config.microvm.vms.kanbei.config.config.microvm.vsock.cid
          ) sourceIds;
        message = "ingest-vm: an ingest guest reuses Kanbei's vsock cid";
      }
      {
        assertion =
          lib.all
            (
              name:
              lib.hasInfix "append:${constants.logDir}/" (
                config.systemd.services.${name}.serviceConfig.StandardOutput or ""
              )
            )
            (
              map (id: "ingest-writer-${id}") sourceIds
              ++ [
                "ingest-proxy"
                "ingest-resolver"
                "ingest-age-key"
                "ingest-heartbeat"
              ]
            );
        message = "ingest-vm: every ingest unit writes a root-only file log";
      }
      {
        assertion = builtins.elem kanbeiLogs config.environment.systemPackages;
        message = "ingest-vm: the touch-gated kanbei-logs viewer must be installed";
      }
      # The digest writer watches a real share: cluster-vm.nix must mount the
      # same host tree into the guest, or the feed silently stops.
      {
        assertion =
          !(config.microvm.vms ? cluster)
          || lib.any (
            share:
            (share.mountPoint or null) == "/mnt/data/cluster-digest" && (share.source or null) == digestShare
          ) config.microvm.vms.cluster.config.config.microvm.shares;
        message = "ingest-vm: the cluster guest must share ${digestShare} at /mnt/data/cluster-digest";
      }
      {
        assertion =
          config.systemd.services.ingest-writer-cluster-digest.restartIfChanged == false
          && lib.hasInfix "append:${constants.logDir}/" (
            config.systemd.services.ingest-writer-cluster-digest.serviceConfig.StandardOutput or ""
          );
        message = "ingest-vm: the digest writer must not restart on a host switch and must log root-only";
      }
      # TutaBridge is a send-capable session: the local servers stay on loopback
      # and the guest's egress remains the single allowlisted Tuta host.
      {
        assertion =
          constants.tutaBridge.bindAddr == "127.0.0.1"
          && constants.tutaBridge.smtpPort == 1025
          && constants.tutaBridge.imapPort == 1143;
        message = "ingest-vm: TutaBridge must stay on loopback with the documented ports";
      }
      {
        assertion = sources.tuta.allow == [ "app.tuta.com" ];
        message = "ingest-vm: the tuta guest may only reach app.tuta.com";
      }
      {
        assertion =
          let
            guest = config.microvm.vms.${sources.tuta.guest}.config.config;
          in
          guest.systemd.services ? tutabridge
          && guest.systemd.services ? tutabridge-session
          && guest.systemd.services ? ingest-tuta-mail
          && guest.systemd.services ? ingest-tuta-ics
          && guest.systemd.timers ? ingest-tuta-ics
          && !(builtins.elem constants.tutaBridge.smtpPort guest.networking.firewall.allowedTCPPorts)
          && !(builtins.elem constants.tutaBridge.imapPort guest.networking.firewall.allowedTCPPorts);
        message = "ingest-vm: the tuta guest needs the bridge, session, mail and ICS units, and no inbound port for 1143/1025";
      }
      # Finance (#590): one SimpleFIN host, Plaid only behind the option, and a
      # daily timer with a memory cap.
      {
        assertion =
          effectiveSources.finance.allow == ingest.financeAllow cfg.financePlaid.enable
          && lib.elem ingest.plaidHost policy.sources.finance.allow == cfg.financePlaid.enable
          && policy == ingest.mkPolicy effectiveSources;
        message = "ingest-vm: the Plaid host may only enter the finance policy when ingestVm.financePlaid.enable is on";
      }
      {
        assertion =
          let
            guest = config.microvm.vms.${sources.finance.guest}.config.config;
          in
          guest.systemd.services ? ingest-finance
          && guest.systemd.timers ? ingest-finance
          && guest.systemd.services.ingest-finance.serviceConfig.Type == "oneshot";
        message = "ingest-vm: the finance guest needs the collector service and its daily timer";
      }
      # Brave (#591): History only, one sync host, and no byte or LAN path.
      {
        assertion =
          sources.brave.allow == [ "sync-v2.brave.com" ]
          && policy.sources.brave.allow == [ "sync-v2.brave.com" ];
        message = "ingest-vm: the brave guest may only reach sync-v2.brave.com";
      }
      {
        assertion =
          let
            guest = config.microvm.vms.${sources.brave.guest}.config.config;
            sync = guest.systemd.services.ingest-brave-sync;
          in
          guest.systemd.services ? ingest-brave-sync
          && guest.systemd.services ? ingest-brave-history
          && guest.systemd.services ? brave-sync-join
          && guest.systemd.timers ? ingest-brave-history
          && lib.hasInfix "--headless=new" (builtins.readFile braveSyncPull)
          && lib.hasInfix "ingest-brave-sync" sync.serviceConfig.ExecStartPre
          && lib.hasInfix "--password-store=basic" (builtins.readFile braveJoinScript);
        message = "ingest-vm: the brave guest needs the seed step, headless pull, History collector and manual join unit";
      }
      # Immich (#592): metadata endpoints only; the host allowlist is one name.
      {
        assertion =
          sources.immich.allow == [ "immich.sammohr.dev" ]
          && policy.sources.immich.allow == [ "immich.sammohr.dev" ];
        message = "ingest-vm: the immich guest may only reach immich.sammohr.dev";
      }
      {
        assertion =
          let
            guest = config.microvm.vms.${sources.immich.guest}.config.config;
          in
          guest.systemd.services ? ingest-immich && guest.systemd.timers ? ingest-immich;
        message = "ingest-vm: the immich guest needs the metadata collector and its timer";
      }
      # Search (#594): one egress name, one query port, a loopback judge and a
      # persisted limiter. Any drift here silently widens the capped channel.
      {
        assertion =
          sources.search.allow == [ "api.search.tinyfish.ai" ]
          && policy.sources.search.allow == [ "api.search.tinyfish.ai" ]
          && searchQueryPort != sources.search.vsockPort;
        message = "ingest-vm: the search guest may only reach api.search.tinyfish.ai on a distinct query port";
      }
      {
        assertion =
          let
            guest = config.microvm.vms.${sources.search.guest}.config.config;
            rendered = builtins.fromJSON guest.environment.etc."kanbei-search/search.json".text;
            judge = guest.systemd.services.search-judge;
            query = guest.systemd.services.searchd;
          in
          guest.systemd.services ? searchd
          && guest.systemd.services ? search-judge
          && guest.environment.etc."kanbei-search/search.json".mode == "0600"
          &&
            rendered.gates == {
              max_query_chars = cfg.searchMaxQueryChars;
              per_minute = cfg.searchPerMinute;
              daily_budget = cfg.searchDailyBudget;
            }
          && rendered.state == "/var/lib/search/limits.json"
          && lib.hasInfix "--host 127.0.0.1 --port 8091" judge.serviceConfig.ExecStart
          && lib.hasInfix "--port ${toString searchQueryPort}" query.serviceConfig.ExecStart;
        message = "ingest-vm: the search guest needs the judge, the query service and the rendered gate config";
      }
      {
        assertion =
          config.systemd.services.search-vm-model.restartIfChanged == false
          && config.systemd.services.search-vm-state.restartIfChanged == false
          && config.systemd.services.search-relay.restartIfChanged == false
          && lib.hasInfix "append:${constants.logDir}/" (
            config.systemd.services.search-relay.serviceConfig.StandardOutput or ""
          )
          && config.systemd.services.search-relay.bindsTo == [ "microvm@kanbei.service" ];
        message = "ingest-vm: the search model stage and relay must not restart on a switch and the relay log stays root-only";
      }
      {
        assertion =
          builtins.match "[0-9a-f]{64}" searchModel.sha256 != null
          && builtins.match "[a-z0-9.-]+/[A-Za-z0-9._-]+" searchModel.repo != null
          && searchModel.size > 0;
        message = "ingest-vm: the Guardian model manifest needs a repo, a positive size and a sha256";
      }
      {
        assertion = lib.all (id: lib.hasAttr id policy.sources) sourceIds;
        message = "ingest-vm: every guest source needs a policy portal entry";
      }
    ];
  };
}
