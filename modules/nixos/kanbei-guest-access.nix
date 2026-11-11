# Guest-side access for kanbei (smores56/sdlc#586, part of #509): TLS, the static UI shell,
# the certificate client, and the passkey stub.
#
# Imported by the guest config in `modules/nixos/kanbei-vm.nix`, so it only evaluates while
# `kanbeiVm.enable` is set. TLS terminates here: the host relay only splices bytes and the
# host ACME responder only signs the guest's CSR.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  access = import ../lib/kanbei-access.nix;
  inference = import ../lib/kanbei-inference.nix { inherit lib; };

  tools = pkgs.runCommandLocal "kanbei-tools" { } ''
    mkdir -p $out
    cp -R ${../lib/kanbei}/. $out/
    # A local test run can leave bytecode in the source tree; it has no place in the image.
    chmod -R u+w $out
    find $out -name __pycache__ -type d -prune -exec rm -rf {} +
  '';

  python = "${pkgs.python3}/bin/python3";
  chatPort = inference.ports.chat;

  uiSandbox = {
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
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
in
{
  systemd.tmpfiles.rules = [
    "d ${access.guestTlsDir} 0700 root root -"
  ];

  # The guest asks, the host signs. The key is generated in the guest's tmpfs and installed
  # 0400 root under the LUKS-backed state directory; only the CSR crosses vsock.
  systemd.services.kanbei-cert = {
    description = "Request or renew the Kanbei TLS certificate from the host ACME responder";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      RequiresMountsFor = [ "/var/lib/kanbei" ];
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 10;
    };
    after = [
      "local-fs.target"
      "systemd-modules-load.service"
    ];
    # The tunnel relay cannot serve anything without a certificate, so the UI waits for this.
    before = [ "${access.guestUiUnit}.service" ];
    restartIfChanged = false;
    serviceConfig = uiSandbox // {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${python} ${tools}/cert_guest.py --state-dir ${access.guestTlsDir} --host-vsock-cid ${toString access.hostVsockCid} --host-vsock-port ${toString access.certVsockPort} --token-file /run/kanbei-secrets/relay-token --openssl ${pkgs.openssl}/bin/openssl --reload-unit ${access.guestUiUnit}.service";
      # The LUKS volume is writable for this unit only; ProtectSystem=strict covers the rest.
      ReadWritePaths = [ "/var/lib/kanbei" ];
      Restart = "on-failure";
      RestartSec = "60s";
    };
  };

  systemd.timers.kanbei-cert = {
    description = "Daily Kanbei certificate renewal attempt";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnCalendar = "*-*-* 03:20:00";
      RandomizedDelaySec = "15min";
      Persistent = true;
    };
  };

  # Static shell + JSON API on AF_VSOCK 10000, TLS with the guest's certificate. The key is
  # root-only at rest and handed to the service through systemd credentials.
  systemd.services.${access.guestUiUnit} = {
    description = "Kanbei UI shell and JSON API (TLS on vsock 10000)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "kanbei-cert.service" ];
    after = [ "kanbei-cert.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/kanbei" ];
    restartIfChanged = false;
    serviceConfig = uiSandbox // {
      User = "kanbei";
      Group = "kanbei";
      LoadCredential = [
        "tls-cert:${access.guestTlsDir}/cert.pem"
        "tls-key:${access.guestTlsDir}/key.pem"
        # The host relay writes this token as the first bytes of every connection; the UI
        # closes a connection that does not present it, before TLS starts.
        "relay-token:/run/kanbei-secrets/relay-token"
      ];
      ExecStart = "${python} ${tools}/ui/server.py --ui-dir ${tools}/ui --vsock-port ${toString access.chatVsockPort} --tls-cert %d/tls-cert --tls-key %d/tls-key --auth-token-file %d/relay-token --chat-upstream http://127.0.0.1:${toString chatPort}";
      Restart = "always";
      RestartSec = "5s";
      RestrictAddressFamilies = [
        "AF_VSOCK"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  assertions = [
    {
      assertion = access.chatVsockPort != access.certVsockPort;
      message = "kanbei-guest-access: the chat and certificate vsock ports must differ";
    }
    {
      assertion =
        lib.hasInfix "--auth-token-file %d/relay-token"
          config.systemd.services.${access.guestUiUnit}.serviceConfig.ExecStart
        &&
          lib.elem "relay-token:/run/kanbei-secrets/relay-token"
            config.systemd.services.${access.guestUiUnit}.serviceConfig.LoadCredential
        && lib.hasInfix "--token-file /run/kanbei-secrets/relay-token" config.systemd.services.kanbei-cert.serviceConfig.ExecStart;
      message = "kanbei-guest-access: the UI and certificate client must present the host relay token";
    }
  ];

  environment.systemPackages = [
    pkgs.openssl
  ];
}
