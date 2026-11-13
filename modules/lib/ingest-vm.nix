# The ingest plane's shared facts and policy (smores56/sdlc#588, part of #509). One guest per
# source, each a Firecracker microVM with exactly one tap, one vsock channel and one read-only
# secret volume; all egress goes through the host proxy and resolver on that tap's host address.
# The `search` guest is the exception by design: it also carries a read-only Guardian model
# volume and a second vsock listener for Kanbei's query API (#594).
#
# Host and guest are generated from this one table so the tap names, /30s, vsock CIDs, ports and
# allowlists cannot drift. The validators are pure: the module asserts they are empty and the
# `kanbei-ingest-guards` check mutates the table to prove a non-allowlisted hostname or an extra
# egress rule fails evaluation.
{ lib }:
let
  # Every path the host writer and the heartbeat share. Quoted in docs/kanbei-ingest.md.
  constants = {
    inboxDir = "/var/lib/data/inbox";
    # The cluster digest writer's dedicated host identity. Guest root and guest uid 1000 are
    # translated onto it for that share only, so `smores` (1000) has no access at all and a
    # compromised cluster workload cannot inject into a tree Kanbei trusts.
    digestUser = "kanbei-digest";
    digestUid = 983;
    stateRoot = "/var/lib/kanbei-ingest";
    # The digest tree lives inside the root-only state root, never under `/var/lib/data`:
    # that directory is `0751 smores:users`, so its owner could rename or replace any child
    # tree regardless of the child's own mode. A 0700 root parent chain makes the share
    # itself the only writable object, and only for the digest uid.
    digestParent = "/var/lib/kanbei-ingest/shares";
    digestDir = "/var/lib/kanbei-ingest/shares/cluster-digest";
    logDir = "/var/log/kanbei-ingest";
    policyFile = "/etc/kanbei-ingest/policy.json";
    # Kanbei publishes its age recipient through this port on its Firecracker vsock. The guest
    # dials host CID 2, so Firecracker listens on <uds>_<port> in the guest's state directory.
    ageKeyPort = 7100;
    # Kanbei's search queries dial host CID 2 on this port; the host relay pipes each
    # connection to the search guest's own query port.
    searchQueryPort = 7101;
    proxyPort = 3128;
    dnsPort = 53;
    protocolVersion = 1;
    maxBatchBytes = 1048576;
    heartbeatIntervalSeconds = 300;
    heartbeatRetainHours = 168;
    # TutaBridge's local servers. SMTP stays on loopback: the guest never
    # exposes a send path to the tap, and the collector only reads IMAP.
    tutaBridge = {
      imapPort = 1143;
      smtpPort = 1025;
      bindAddr = "127.0.0.1";
    };
  };

  # The maximum each source may ever be allowed to reach. A per-source `allow` that names
  # anything outside this table fails `validateSources`.
  permitted = {
    tuta = [ "app.tuta.com" ];
    # The Plaid host is permitted by the table but reaches a guest's allowlist
    # only through `financeAllow`, which the module drives from its off-by-default
    # option (#590).
    finance = [
      "bridge.simplefin.org"
      "production.plaid.com"
    ];
    brave = [ "sync-v2.brave.com" ];
    immich = [ "photos.sammohr.dev" ];
    # The search guest is the only egress for Kanbei's capped queries; Kanbei holds no NIC.
    search = [ "api.search.tinyfish.ai" ];
  };

  plaidHost = "production.plaid.com";

  # The finance guest's effective allowlist: SimpleFIN always, Plaid only when
  # the owner enables the fallback.
  financeAllow = plaid: [ "bridge.simplefin.org" ] ++ lib.optional plaid plaidHost;

  sources = {
    tuta = {
      guest = "ingest-tuta";
      tap = "vm-i-tuta";
      index = 10;
      vsockCid = 10;
      vsockPort = 7010;
      vcpu = 1;
      mem = 256;
      # One read-only volume: the secret image.
      volumes = 1;
      # TutaBridge holds an IMAP IDLE session; half an hour without a batch is already wrong.
      windowSeconds = 1800;
      allow = permitted.tuta;
    };
    finance = {
      guest = "ingest-finance";
      tap = "vm-i-finance";
      index = 11;
      vsockCid = 11;
      vsockPort = 7011;
      vcpu = 1;
      # 256 is the boot floor: the initramfs unpacks to 68 MiB and 192 MiB panics.
      mem = 256;
      volumes = 1;
      # SimpleFIN is polled daily; 36 h covers one missed run plus a retry.
      windowSeconds = 129600;
      allow = financeAllow false;
    };
    brave = {
      guest = "ingest-brave";
      tap = "vm-i-brave";
      index = 12;
      vsockCid = 12;
      vsockPort = 7012;
      vcpu = 1;
      mem = 1024;
      volumes = 1;
      # Sync is pulled once a day by the headful Xvfb paste session.
      windowSeconds = 86400;
      allow = permitted.brave;
    };
    immich = {
      guest = "ingest-immich";
      tap = "vm-i-immich";
      index = 13;
      vsockCid = 13;
      vsockPort = 7013;
      vcpu = 1;
      # 256 is the boot floor: the initramfs unpacks to 68 MiB and 128 MiB panics.
      mem = 256;
      volumes = 1;
      # The timer runs four times a day; an 18 h window makes one missed pass silent
      # and two a page, without letting the 15 min jitter trip it.
      windowSeconds = 64800;
      allow = permitted.immich;
    };
    search = {
      guest = "search";
      tap = "vm-search";
      index = 14;
      vsockCid = 14;
      # The batch port carries the verifier's seeded batch to the host writer.
      vsockPort = 7014;
      # The query API is a second listener; one port cannot serve both protocols.
      queryPort = 7024;
      vcpu = 2;
      # 1.44 GiB of mmapped Guardian weights plus the judge runtime and the guest userland.
      mem = 2560;
      # Secret image, the read-only Guardian model image, and the writable limiter volume.
      volumes = 3;
      # The search guest has no production emitter yet; its test emitter feeds the verifier.
      windowSeconds = 86400;
      allow = permitted.search;
      # The test emitter only feeds kanbei-ingest-verify; staleness is visible but does not page.
      alert = false;
    };
  };

  # Sources the host itself writes into the plane (no guest, no tap, no
  # allowlist): the cluster digest lands on its own root-parented share, and the
  # host writer encrypts it exactly like a guest batch. The heartbeat treats them
  # as sources for freshness and alerting.
  hostSources = {
    cluster-digest = {
      windowSeconds = 3600;
      # The CronJob runs every 15 minutes; the writer pages on staleness with
      # the same marker, so the heartbeat and the writer never double-page.
      alert = true;
    };
  };

  sourceIds = builtins.attrNames sources;

  factsOf =
    tbl: id:
    import ./vm-host.nix {
      name = tbl.${id}.guest;
      inherit (tbl.${id}) index vsockCid;
      tapName = tbl.${id}.tap;
    };

  factsFor = factsOf sources;

  entries = map (
    id:
    sources.${id}
    // {
      inherit id;
      facts = factsFor id;
    }
  ) sourceIds;

  # Per-tap iptables chains. The INPUT chain only admits the proxy and resolver on the tap's
  # host address; the FORWARD chain has no ACCEPT other than conntrack, so a guest can never
  # route to the LAN, the internet or another tap.
  chainIn = id: "ingest-${id}-in";
  chainFwd = id: "ingest-${id}-fwd";

  # The operator-staged contract for a source, named for its sops key. One definition:
  # the staging unit and docs/manual-steps.md must agree on it exactly.
  secretPath = id: "/run/secrets/ingest-${id}-env";

  firewallRulesFor =
    id:
    let
      f = factsFor id;
    in
    [
      "-A ${chainIn id} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      "-A ${chainIn id} -p tcp -d ${f.hostAddr} --dport ${toString constants.proxyPort} -j ACCEPT"
      "-A ${chainIn id} -p udp -d ${f.hostAddr} --dport ${toString constants.dnsPort} -j ACCEPT"
      "-A ${chainIn id} -j DROP"
      "-A ${chainFwd id} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      "-A ${chainFwd id} -i ${f.tap} -o vm-+ -j DROP"
      "-A ${chainFwd id} -o ${f.tap} -i vm-+ -j DROP"
      "-A ${chainFwd id} -j DROP"
    ];

  firewallRules = lib.concatMap firewallRulesFor sourceIds;

  firewallTable = lib.concatStringsSep "\n" (
    [
      "*filter"
    ]
    ++ lib.concatMap (id: [
      ":${chainIn id} - [0:0]"
      ":${chainFwd id} - [0:0]"
    ]) sourceIds
    ++ firewallRules
    ++ [ "COMMIT" ]
  );

  firewallUp = lib.concatStringsSep "\n" (
    [ "iptables-restore -w --noflush /etc/kanbei-ingest/rules.v4" ]
    ++ lib.concatMap (id: [
      "iptables -w -C INPUT -i ${(factsFor id).tap} -j ${chainIn id} 2>/dev/null || iptables -w -I INPUT 1 -i ${(factsFor id).tap} -j ${chainIn id}"
      "iptables -w -C FORWARD -i ${(factsFor id).tap} -j ${chainFwd id} 2>/dev/null || iptables -w -I FORWARD 1 -i ${(factsFor id).tap} -j ${chainFwd id}"
      "iptables -w -C FORWARD -o ${(factsFor id).tap} -j ${chainFwd id} 2>/dev/null || iptables -w -I FORWARD 1 -o ${(factsFor id).tap} -j ${chainFwd id}"
    ]) sourceIds
  );

  # Hostname grammar: lowercase DNS labels, at least one dot, no scheme/port/path, never an IP
  # literal. Matching is exact (no wildcards) so a resolver answer cannot widen the allowlist.
  hostnameOk =
    h:
    builtins.isString h
    && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+" h != null
    && builtins.match "[0-9.]+" h == null
    && builtins.match ".*\\.\\." h == null;

  validateSources =
    tbl:
    lib.concatMap (
      id:
      let
        s = tbl.${id};
        badAllow = builtins.filter (a: !(hostnameOk a) || !(lib.elem a (permitted.${id} or [ ]))) s.allow;
      in
      lib.optional (builtins.match "[a-z][a-z0-9-]*" id == null) "source id ${id} is not a lowercase slug"
      ++ lib.optional (
        !(builtins.isString s.guest) || builtins.match "[a-z][a-z0-9-]*" s.guest == null
      ) "source ${id}: guest name ${toString s.guest} is not a lowercase slug"
      ++ map (a: "source ${id}: hostname ${a} is not allowlisted") badAllow
      ++ lib.optional (s.index <= 0 || s.index >= 256) "source ${id}: index must be 1..255"
      ++ lib.optional (s.vsockCid <= 2) "source ${id}: vsock cid must be > 2"
      ++ lib.optional (
        s.vsockPort < 1024 || s.vsockPort >= 1073741824
      ) "source ${id}: vsock port must be an unprivileged port outside the Firecracker host range"
      ++ lib.optional (s.mem < 256) (
        "source ${id}: mem must be at least 256 MiB; the 68 MiB initramfs plus the kernel"
        + " deadlocks the guest on memory in unpack_to_rootfs below that"
      )
      ++ lib.optional (
        !(builtins.isInt s.volumes) || s.volumes < 1 || s.volumes > 3
      ) "source ${id}: volumes must be 1..3"
      ++ lib.optional (
        s ? queryPort && (s.queryPort < 1024 || s.queryPort >= 1073741824 || s.queryPort == s.vsockPort)
      ) "source ${id}: queryPort must be a distinct unprivileged port"
      ++ lib.optional (s.windowSeconds <= 0) "source ${id}: window must be positive"
    ) (builtins.attrNames tbl);

  validateHostSources =
    tbl:
    lib.concatMap (
      id:
      let
        s = tbl.${id};
      in
      lib.optional (builtins.elem id sourceIds) "host source ${id} collides with a guest source"
      ++ lib.optional (s.windowSeconds <= 0) "host source ${id}: window must be positive"
    ) (builtins.attrNames tbl);

  # Catches two guests sharing a tap, state path, vsock cid or vsock port.
  validateFacts =
    tbl:
    let
      ids = builtins.attrNames tbl;
      field = f: map f ids;
      dupes =
        f: name:
        lib.optional (lib.length (lib.unique (field f)) != lib.length ids) "${name} values are not unique";
    in
    dupes (id: (factsOf tbl id).tap) "tap"
    ++ dupes (id: (factsOf tbl id).stateDir) "stateDir"
    ++ dupes (id: toString tbl.${id}.vsockCid) "vsock cid"
    ++ dupes (id: toString tbl.${id}.vsockPort) "vsock port"
    ++ lib.optional (
      let
        queryPorts = map (id: tbl.${id}.queryPort) (builtins.filter (id: tbl.${id} ? queryPort) ids);
      in
      lib.length (lib.unique queryPorts) != lib.length queryPorts
    ) "query port values are not unique";

  # Every rule must be one this table generates. An ACCEPT in the forward chain other than
  # conntrack, or any mention of a foreign tap, is an extra egress path and fails eval.
  validateFirewall =
    {
      tbl,
      rules,
    }:
    let
      lines = builtins.filter (l: l != "") (lib.splitString "\n" rules);
      ids = builtins.attrNames tbl;
      otherTaps =
        id: builtins.filter (t: t != (factsOf tbl id).tap) (map (other: (factsOf tbl other).tap) ids);
      chainOf = prefix: id: "${prefix}-${id}";
      fwdLines = id: builtins.filter (l: lib.hasPrefix "-A ${chainOf "ingest" id}-fwd " l) lines;
      inLines = id: builtins.filter (l: lib.hasPrefix "-A ${chainOf "ingest" id}-in " l) lines;
      hostAddr = id: (factsOf tbl id).hostAddr;
      fwdOk =
        id:
        let
          ls = fwdLines id;
        in
        map (
          l:
          if lib.hasInfix "conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" l then
            null
          else if lib.hasSuffix "-j DROP" l then
            null
          else
            "source ${id}: forward rule grants egress: ${l}"
        ) ls
        ++ lib.optional (
          !(lib.any (l: lib.hasSuffix "-j DROP" l) ls)
        ) "source ${id}: forward chain has no final DROP";
      inOk =
        id:
        map (
          l:
          if lib.hasInfix "conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" l then
            null
          else if
            lib.hasInfix "-p tcp -d ${hostAddr id} --dport ${toString constants.proxyPort} -j ACCEPT" l
            || lib.hasInfix "-p udp -d ${hostAddr id} --dport ${toString constants.dnsPort} -j ACCEPT" l
            || lib.hasSuffix "-j DROP" l
          then
            null
          else
            "source ${id}: input rule is not the proxy/resolver: ${l}"
        ) (inLines id);
      foreign =
        id:
        map (t: "source ${id}: rules mention foreign tap ${t}") (
          builtins.filter (t: lib.any (l: lib.hasInfix t l) (fwdLines id ++ inLines id)) (otherTaps id)
        );
    in
    lib.filter (e: e != null) (
      lib.concatMap (id: fwdOk id ++ inOk id ++ foreign id) ids
      ++ lib.optional (lib.any (l: lib.hasPrefix "*nat" l) lines) "firewall text contains a nat table"
      ++ lib.optional (
        builtins.length (builtins.filter (l: lib.hasPrefix "-A " l) lines) != builtins.length firewallRules
      ) "firewall text is not exactly the generated rule set"
    );

  # The policy file every host service reads. Names only; no secret material.
  # `sources` is the table to render, so the module can flip the Plaid host
  # without a second copy of the allowlist.
  mkPolicy = tbl: {
    inherit constants permitted hostSources;
    sources = builtins.listToAttrs (
      map (id: {
        name = id;
        value = {
          inherit (tbl.${id})
            guest
            allow
            windowSeconds
            vsockPort
            ;
          alert = tbl.${id}.alert or true;
          inherit (factsOf tbl id) tap;
          gateway = (factsOf tbl id).hostAddr;
          client = (factsOf tbl id).guestAddr;
        };
      }) (builtins.attrNames tbl)
    );
  };

  policy = mkPolicy sources;
in
constants
// {
  inherit
    constants
    permitted
    sources
    hostSources
    sourceIds
    entries
    factsFor
    chainIn
    chainFwd
    secretPath
    firewallRulesFor
    firewallRules
    firewallTable
    firewallUp
    hostnameOk
    validateSources
    validateHostSources
    validateFacts
    validateFirewall
    plaidHost
    financeAllow
    mkPolicy
    policy
    ;
}
