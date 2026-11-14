# The kanbei agent kernel (smores56/sdlc#614, part of #509): the flake-pinned `kanbei`
# package, its manifest and observed posture, the age identity and recipient publisher, and
# the two UDS->vsock bridges the kernel dials for CSR and search.
#
# Imported by the guest config in `modules/nixos/kanbei-vm.nix`, so it only evaluates while
# `kanbeiVm.enable` is set. The kernel is the trusted control plane and runs as its own
# non-root uid: it reads the root-only inbox batches and writes Todo through the share
# translations, and it is the only non-root identity that can reach the bridge sockets.
# Guest root can always assume any uid; the mapping keeps the payload uid 1000 and every
# other non-root uid out. The future agent sandbox keeps the documented payload uid 1000.
{
  config,
  lib,
  pkgs,
  kanbeiInput,
  ...
}:
let
  access = import ../lib/kanbei-access.nix;
  agentFacts = import ../lib/kanbei-agent.nix;
  ingest = import ../lib/ingest-vm.nix { inherit lib; };
  inference = import ../lib/kanbei-inference.nix { inherit lib; };
  hardening = import ../lib/hardening.nix;

  user = agentFacts.coreUser;
  group = agentFacts.coreGroup;
  uid = agentFacts.coreUid;
  gid = agentFacts.coreGid;
  # systemd hands the root-only relay token to the unit through a credential directory;
  # KANBEI_RELAY_TOKEN must name the materialized copy, not the source on the share.
  credentialDir = "/run/credentials/kanbei.service";

  stateDir = "/var/lib/kanbei/agent";
  runDir = "/run/kanbei";
  etcDir = "/etc/kanbei";
  identityDir = "${stateDir}/age";
  identityFile = "${identityDir}/identity.txt";
  recipientFile = "${identityDir}/recipient.txt";
  relayTokenFile = "/run/kanbei-secrets/relay-token";
  csrSocket = "${runDir}/csr.sock";
  searchSocket = "${runDir}/search.sock";

  # The inference lanes own 8090-8092; these are the kernel's own loopback listeners.
  chatPort = 8080;
  statusPort = 8081;

  generation = "kanbei-1";
  epoch = "1";

  # The mounts the kernel actually uses. `runtime` is socket access only; the two rw paths
  # are exactly `writableRoots`, as the manifest schema requires.
  mounts = [
    {
      path = "/nix/store";
      access = "ro";
      class = "image";
    }
    {
      path = "/mnt/kanbei/inbox";
      access = "ro";
      class = "inbox";
    }
    {
      path = "/mnt/kanbei/vault";
      access = "ro";
      class = "vault";
    }
    {
      path = "/mnt/kanbei/todo";
      access = "rw";
      class = "todo";
    }
    {
      path = stateDir;
      access = "rw";
      class = "agent_state";
    }
    {
      path = runDir;
      access = "ro";
      class = "runtime";
    }
  ];
  writableRoots = [
    "/mnt/kanbei/todo"
    stateDir
  ];
  channels = [
    "inbox"
    "vault"
    "todo"
    "chat"
    "csr"
    "search"
  ];

  # `enforcementRequired: none` is the honest value: no cgroup or Monty verifier exists in
  # this generation, so claiming a stronger class would let a weaker posture boot.
  manifest = {
    sandboxId = "kanbei";
    agentId = "life-admin";
    inherit generation;
    cgroupPath = "/kanbei/agent";
    enforcementRequired = "none";
    inherit mounts writableRoots channels;
    limits = {
      wallMs = 86400000;
      memoryBytes = 4294967296;
      pidsMax = 1024;
      cpuQuota = 800000;
      openFiles = 65536;
      todoBytes = 65536;
    };
  };
  posture = {
    enforcement = "none";
    inherit generation;
    addresses = [ "lo" ];
    channelSockets = channels;
    inherit mounts writableRoots;
  };

  # Full `bootConfigFromEnv` contract (kanbei `src/main.ts:171-256`). The optional
  # freshness/batch knobs carry their documented defaults; the chat upstream is the local
  # llama.cpp lane, so the agent chat surface answers instead of returning "no lane".
  agentEnv = [
    "KANBEI_MANIFEST=${etcDir}/manifest.json"
    "KANBEI_POSTURE=${etcDir}/posture.json"
    "KANBEI_STATE_DIR=${stateDir}"
    "KANBEI_INBOX_DIR=/mnt/kanbei/inbox"
    "KANBEI_IDENTITY=${identityFile}"
    "KANBEI_TODO_DIR=/mnt/kanbei/todo"
    "KANBEI_CSR_SOCKET=${csrSocket}"
    "KANBEI_SEARCH_SOCKET=${searchSocket}"
    "KANBEI_RELAY_TOKEN=${credentialDir}/relay-token"
    "KANBEI_CSR_STATE_DIR=${stateDir}/csr"
    "KANBEI_SEARCH_BUDGET=${stateDir}/search-budget.json"
    "KANBEI_POINTERS=${stateDir}/pointers"
    "KANBEI_CHAT_ORIGIN=https://${access.hostname}"
    "KANBEI_CHAT_LISTEN=127.0.0.1:${toString chatPort}"
    "KANBEI_STATUS_LISTEN=127.0.0.1:${toString statusPort}"
    "KANBEI_EPOCH=${epoch}"
    "KANBEI_ORIGINS=tuta,tuta-mail,tuta-calendar,finance,brave,immich,phone,cluster-digest"
    "KANBEI_FRESHNESS_WINDOW_MS=3600000"
    "KANBEI_MAX_BATCHES_PER_POLL=20"
    "KANBEI_CHAT_UPSTREAM=http://127.0.0.1:${toString inference.ports.chat}/"
  ];

  python = "${pkgs.python3}/bin/python3";
  tools = pkgs.runCommandLocal "kanbei-agent-tools" { } ''
    mkdir -p $out
    cp -R ${../lib/kanbei}/. $out/
    chmod -R u+w $out
    find $out -name __pycache__ -type d -prune -exec rm -rf {} +
  '';

  # Deno gates AF_UNIX dials with `--allow-net=unix:<path>`, and the packaged wrapper only
  # grants loopback. It also cannot see a systemd credential directory, so the relay token
  # from `LoadCredential` needs an extra read root. Extend the vendored wrapper instead of
  # forking the upstream package; `--replace-fail` turns a wrapper change into a build
  # failure rather than a dead bridge or an unreadable token.
  kanbeiPackage = kanbeiInput.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      substituteInPlace $out/bin/kanbei \
        --replace-fail \
          "--allow-read=/mnt/kanbei/inbox," \
          "--allow-read=/run/credentials,/mnt/kanbei/inbox," \
        --replace-fail \
          "--allow-net=127.0.0.1" \
          "--allow-net=127.0.0.1,unix:${csrSocket},unix:${searchSocket}"
    '';
  });

  bridgeSandbox = hardening // {
    PrivateDevices = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_VSOCK"
    ];
    SystemCallArchitectures = "native";
    SystemCallFilter = "@system-service";
    UMask = "0077";
  };

  identitySandbox = hardening // {
    PrivateDevices = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = "@system-service";
    UMask = "0077";
  };

  agentSandbox = hardening // {
    PrivateDevices = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    LockPersonality = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    # V8 needs writable+executable mappings; MemoryDenyWriteExecute would kill Deno.
    # No SystemCallFilter either: Deno's runtime syscall set is wider than @system-service.
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
    SystemCallArchitectures = "native";
    UMask = "0077";
  };
in
{
  # The trusted kernel identity. It is in the `kanbei` group only to traverse the 0750
  # `/var/lib/kanbei` mount (which also lets it list the sibling phone directories; their
  # contents stay root-only); the shares use its own uid/gid through the translations.
  users.groups.${group} = {
    inherit gid;
  };
  users.users.${user} = {
    isSystemUser = true;
    inherit uid group;
    extraGroups = [ "kanbei" ];
    home = stateDir;
    description = "kanbei agent kernel (trusted control plane)";
  };

  environment.systemPackages = [ kanbeiPackage ];

  environment.etc."kanbei/manifest.json".text = builtins.toJSON manifest;
  environment.etc."kanbei/posture.json".text = builtins.toJSON posture;

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 ${user} ${group} -"
    "d ${identityDir} 0700 ${user} ${group} -"
    "d ${stateDir}/cas 0700 ${user} ${group} -"
    "d ${stateDir}/csr 0700 ${user} ${group} -"
    "d ${stateDir}/pointers 0700 ${user} ${group} -"
    "d ${runDir} 0700 ${user} ${group} -"
  ];

  # The LUKS volume root is root-owned, and every service that writes into it runs as
  # kanbei-core. Create its state directory as root once the mount is up; the age unit then
  # creates its own 0700 subdirectory underneath.
  systemd.services.kanbei-agent-state = {
    description = "Create the kanbei agent state directory on the LUKS volume";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/kanbei" ];
    before = [
      "kanbei-age-identity.service"
      "kanbei.service"
    ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      install -d -m 0700 -o ${user} -g ${group} ${stateDir} ${identityDir}
    '';
  };

  # The identity lives on the LUKS volume: a regenerated key would make every batch the host
  # already encrypted to the previous recipient undecryptable.
  systemd.services.kanbei-age-identity = {
    description = "Generate the kanbei agent's age identity and public recipient";
    wantedBy = [ "multi-user.target" ];
    before = [
      "kanbei.service"
      "kanbei-age-publish.service"
    ];
    unitConfig.RequiresMountsFor = [ "/var/lib/kanbei" ];
    after = [ "local-fs.target" ];
    restartIfChanged = false;
    # `path` and `script` are unit-level NixOS options, not [Service] directives; putting
    # them in serviceConfig yields a unit with no ExecStart.
    path = [
      pkgs.age
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail
      umask 077
      install -d -m 0700 ${identityDir}
      if [ ! -s ${identityFile} ]; then
        # age-keygen refuses to overwrite; a zero-byte file from a crash must not wedge us.
        rm -f ${identityFile}
        age-keygen -o ${identityFile} 2>/dev/null
      fi
      chmod 0400 ${identityFile}
      age-keygen -y ${identityFile} > ${recipientFile}.tmp
      chmod 0400 ${recipientFile}.tmp
      mv ${recipientFile}.tmp ${recipientFile}
    '';
    serviceConfig = identitySandbox // {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      Group = group;
      ReadWritePaths = [ identityDir ];
    };
  };

  # The host ingest writer blocks until this file exists, so publish early and retry forever:
  # the host may boot after the guest, and an ingest restart may lose the file.
  systemd.services.kanbei-age-publish = {
    description = "Publish the kanbei age recipient to the host ingest writer";
    wantedBy = [ "multi-user.target" ];
    requires = [ "kanbei-age-identity.service" ];
    after = [ "kanbei-age-identity.service" ];
    # `StartLimitIntervalSec` is a [Unit] setting; the job is allowed to retry forever.
    unitConfig = {
      RequiresMountsFor = [ "/run/kanbei-secrets" ];
      StartLimitIntervalSec = 0;
    };
    restartIfChanged = false;
    serviceConfig = identitySandbox // {
      Type = "oneshot";
      User = user;
      Group = group;
      Restart = "on-failure";
      RestartSec = "60s";
      LoadCredential = [ "relay-token:${relayTokenFile}" ];
      RestrictAddressFamilies = [ "AF_VSOCK" ];
      ExecStart = "${python} ${tools}/age_publish.py --recipient-file ${recipientFile} --token-file %d/relay-token --vsock-cid ${toString access.hostVsockCid} --vsock-port ${toString ingest.constants.ageKeyPort}";
    };
  };

  # The host file survives an ingest restart, but a wiped state directory would otherwise
  # wait for the next guest boot; re-publishing the same recipient is harmless.
  systemd.timers.kanbei-age-publish = {
    description = "Re-publish the kanbei age recipient every six hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitInactiveSec = "6h";
      RandomizedDelaySec = "5min";
    };
  };

  # Deno cannot dial AF_VSOCK and the host listeners are not UDS, so each channel gets a
  # byte pipe. The kernel uid owns the socket 0600: only the kernel can reach a host
  # channel without first becoming that uid.
  systemd.services.kanbei-csr-bridge = {
    description = "Kanbei CSR bridge: UDS ${csrSocket} to vsock ${toString access.hostVsockCid}:${toString access.certVsockPort}";
    wantedBy = [ "multi-user.target" ];
    after = [
      "local-fs.target"
      "systemd-tmpfiles-setup.service"
    ];
    before = [ "kanbei.service" ];
    restartIfChanged = false;
    serviceConfig = bridgeSandbox // {
      Type = "notify";
      User = user;
      Group = group;
      Restart = "always";
      RestartSec = "2s";
      ReadWritePaths = [ runDir ];
      ExecStart = "${python} ${tools}/uds_forward.py --listen ${csrSocket} --vsock-cid ${toString access.hostVsockCid} --vsock-port ${toString access.certVsockPort}";
    };
  };

  systemd.services.kanbei-search-bridge = {
    description = "Kanbei search bridge: UDS ${searchSocket} to vsock ${toString access.hostVsockCid}:${toString ingest.constants.searchQueryPort}";
    wantedBy = [ "multi-user.target" ];
    after = [
      "local-fs.target"
      "systemd-tmpfiles-setup.service"
    ];
    before = [ "kanbei.service" ];
    restartIfChanged = false;
    serviceConfig = bridgeSandbox // {
      Type = "notify";
      User = user;
      Group = group;
      Restart = "always";
      RestartSec = "2s";
      ReadWritePaths = [ runDir ];
      ExecStart = "${python} ${tools}/uds_forward.py --listen ${searchSocket} --vsock-cid ${toString access.hostVsockCid} --vsock-port ${toString ingest.constants.searchQueryPort}";
    };
  };

  systemd.services.kanbei = {
    description = "Kanbei agent kernel (posture-verified control plane)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "kanbei-age-identity.service" ];
    after = [
      "kanbei-age-identity.service"
      "kanbei-csr-bridge.service"
      "kanbei-search-bridge.service"
      "local-fs.target"
    ];
    # A bridge or the chat lane may restart without taking the kernel down; the channel
    # dial simply fails until the bridge is back. Ordering still waits for both sockets.
    wants = [
      "kanbei-chat.service"
      "kanbei-csr-bridge.service"
      "kanbei-search-bridge.service"
    ];
    unitConfig = {
      RequiresMountsFor = [
        "/var/lib/kanbei"
        "/run/kanbei-secrets"
        "/mnt/kanbei/inbox"
        "/mnt/kanbei/vault"
        "/mnt/kanbei/todo"
      ];
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 10;
    };
    restartIfChanged = false;
    serviceConfig = agentSandbox // {
      Type = "simple";
      User = user;
      Group = group;
      Restart = "on-failure";
      RestartSec = "10s";
      LoadCredential = [ "relay-token:${relayTokenFile}" ];
      Environment = agentEnv;
      # The kernel writes agent state and Todo; everything else is read-only or a socket.
      ReadWritePaths = [
        stateDir
        "/mnt/kanbei/todo"
      ];
      ExecStart = "${kanbeiPackage}/bin/kanbei";
    };
  };

  assertions = [
    {
      assertion =
        posture.addresses == [ "lo" ]
        && posture.enforcement == "none"
        && manifest.enforcementRequired == "none";
      message = "kanbei-agent: the guest is NIC-less and no enforcement class exists, so the observed posture must be addresses=[\"lo\"] and enforcement none (required none)";
    }
    {
      assertion = lib.all (mount: (lib.elem mount.path writableRoots) == (mount.access == "rw")) mounts;
      message = "kanbei-agent: writableRoots must name exactly the rw mounts";
    }
    {
      assertion = lib.all (name: lib.any (entry: lib.hasPrefix "${name}=" entry) agentEnv) [
        "KANBEI_MANIFEST"
        "KANBEI_POSTURE"
        "KANBEI_STATE_DIR"
        "KANBEI_INBOX_DIR"
        "KANBEI_IDENTITY"
        "KANBEI_TODO_DIR"
        "KANBEI_CSR_SOCKET"
        "KANBEI_SEARCH_SOCKET"
        "KANBEI_RELAY_TOKEN"
        "KANBEI_CSR_STATE_DIR"
        "KANBEI_SEARCH_BUDGET"
        "KANBEI_POINTERS"
        "KANBEI_CHAT_ORIGIN"
        "KANBEI_CHAT_LISTEN"
        "KANBEI_STATUS_LISTEN"
        "KANBEI_EPOCH"
        "KANBEI_ORIGINS"
      ];
      message = "kanbei-agent: the service must carry the full KANBEI_* boot contract";
    }
    {
      assertion =
        lib.hasInfix "--listen ${csrSocket} --vsock-cid ${toString access.hostVsockCid} --vsock-port ${toString access.certVsockPort}" config.systemd.services.kanbei-csr-bridge.serviceConfig.ExecStart
        && lib.hasInfix "--listen ${searchSocket} --vsock-cid ${toString access.hostVsockCid} --vsock-port ${toString ingest.constants.searchQueryPort}" config.systemd.services.kanbei-search-bridge.serviceConfig.ExecStart;
      message = "kanbei-agent: the two bridges must dial the host CSR and search vsock ports the host modules listen on";
    }
    {
      assertion =
        lib.elem "kanbei.service" config.systemd.services.kanbei-csr-bridge.before
        && lib.elem "kanbei.service" config.systemd.services.kanbei-search-bridge.before;
      message = "kanbei-agent: both bridges must be listening before the kernel starts";
    }
    {
      assertion = config.systemd.services.kanbei.serviceConfig.User == user;
      message = "kanbei-agent: the kernel must run as its dedicated uid, not root and not the payload uid 1000";
    }
    {
      assertion = lib.elem "relay-token:${relayTokenFile}" config.systemd.services.kanbei.serviceConfig.LoadCredential;
      message = "kanbei-agent: the kernel must receive the root-only relay token as a systemd credential";
    }
    {
      # The share translation is the authority grant: guest root stays `nobody`, only the
      # kernel uid may map to host root (inbox) or vault (vault/todo), and no other guest
      # uid may acquire either. This is what an edit widening the mapping must trip.
      assertion =
        let
          shares = config.microvm.shares;
          uidText = toString uid;
          find = tag: lib.findFirst (s: s.tag == tag) null shares;
          mapsTo =
            guest: host: args:
            lib.any (arg: arg == "--translate-uid=guest:${guest}:${host}:1") args
            && lib.any (arg: arg == "--translate-gid=guest:${guest}:${host}:1") args;
          rootIsNobody =
            args:
            mapsTo "0" "65534" args
            && lib.all (
              arg:
              let
                match = builtins.match "--translate-(uid|gid)=guest:([0-9]+):0(:[0-9]+)?" arg;
              in
              match == null || builtins.elemAt match 1 == uidText
            ) args;
          coreMapsToVault =
            args:
            lib.any (
              arg:
              lib.hasPrefix "--translate-uid=guest:${uidText}:" arg
              && !(lib.hasPrefix "--translate-uid=guest:${uidText}:0" arg)
            ) args
            && lib.any (
              arg:
              lib.hasPrefix "--translate-gid=guest:${uidText}:" arg
              && !(lib.hasPrefix "--translate-gid=guest:${uidText}:0" arg)
            ) args;
          vault = find "vault";
          inbox = find "inbox";
          dataShares = [
            vault
            (find "todo")
          ];
        in
        lib.all (
          share:
          share != null && rootIsNobody (share.extraArgs or [ ]) && coreMapsToVault (share.extraArgs or [ ])
        ) dataShares
        && vault != null
        && vault.readOnly == true
        && inbox != null
        && inbox.readOnly == true
        && rootIsNobody (inbox.extraArgs or [ ])
        && mapsTo uidText "0" (inbox.extraArgs or [ ]);
      message = "kanbei-agent: only the kernel uid may map to host root (inbox) or vault (vault/todo); guest root must stay nobody on all three";
    }
  ];
}
