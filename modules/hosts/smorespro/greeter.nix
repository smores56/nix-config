# smorespro greeter and lock-screen PAM: fingerprint, YubiKey PIV PIN, then password,
# each tried only when usable.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # pam_exec has no PATH, so each probe carries its own. A probe that cannot run
  # fails open: it costs the fingerprint path, never the password.
  # Exit 0 = lid closed: skip pam_fprintd.
  lidClosed = pkgs.writeShellApplication {
    name = "pam-lid-closed";
    runtimeInputs = [
      config.systemd.package
    ];
    text = ''
      # Single test, no pipeline: SIGPIPE under pipefail would report the lid as open.
      [ "$(busctl --system --timeout=1 get-property \
        org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager LidClosed)" = "b true" ]
    '';
  };

  # Exit 0 = no CCID interface: skip pam_p11. Scanning sysfs (~9 ms) avoids pcsc
  # enumeration (~2 s with no token). Detects a reader, not a card.
  ccidAbsent = pkgs.writeShellApplication {
    name = "pam-ccid-absent";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      found=0
      for f in /sys/bus/usb/devices/*/bInterfaceClass; do
        [ -r "$f" ] || continue
        if [ "$(cat "$f")" = "0b" ]; then
          found=1
          break
        fi
      done
      [ "$found" -eq 0 ]
    '';
  };

  # success=1 skips the next line, so `enable` ties the gate to the module it guards.
  gate = enable: order: probe: {
    inherit enable;
    inherit order;
    control = "[success=1 default=ignore]";
    modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
    args = [
      "quiet"
      "quiet_log"
      (lib.getExe probe)
    ];
  };

  # pam_p11 grants, denies, or steps aside, never a second prompt (noctalia 5.3.0
  # turns one into an error). authinfo_unavail falls through so a foreign reader,
  # rotated cert, or locked PIV cannot lock out the password; anything else denies,
  # so a typed password never burns a PIV retry.
  p11Control = "[success=done authinfo_unavail=ignore default=die]";

  # pam_p11 reads $HOME/.eid/authorized_certificates with no override. A symlink
  # could be unlinked by a same-uid agent; a read-only bind mount cannot.
  pamP11Certificates = lib.concatStringsSep "\n" (
    map (key: key.cert) (import ../../lib/yubikey-keys.nix).piv
  );
  eidPath = "/home/${config.machine.username}/.eid";
in
{
  imports = [ inputs.noctalia-greeter.nixosModules.default ];

  environment.etc."eid/authorized_certificates".text = pamP11Certificates + "\n";

  # Fails safe: if unready, pam_p11 finds no cert and the password still works.
  systemd.services.pam-p11-trust = {
    description = "Bind the managed pam_p11 trust file over ~/.eid";
    wantedBy = [ "multi-user.target" ];
    after = [ "nixos-activation.service" ];
    before = [
      "greetd.service"
      "systemd-user-sessions.service"
    ];
    path = [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Needs a real, empty mountpoint; best-effort so a reboot while mounted still starts.
      ExecStartPre = [
        "-${pkgs.util-linux}/bin/umount ${lib.escapeShellArg eidPath}"
        "-${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg eidPath}"
        "${pkgs.coreutils}/bin/mkdir -p -m 0755 ${lib.escapeShellArg eidPath}"
      ];
      ExecStart = "${pkgs.util-linux}/bin/mount --bind /etc/eid ${lib.escapeShellArg eidPath}";
      ExecStartPost = "${pkgs.util-linux}/bin/mount -o remount,bind,ro ${lib.escapeShellArg eidPath}";
    };
  };

  services.displayManager.noctalia-greeter = {
    enable = true;
    passwordless-sync-users = [ ];
    # An empty submit starts the PAM conversation (and fprintd).
    settings.auth.allow_empty_password = true;
  };

  # Fingerprint first; the lid gate skips the ~5 s wait when the sensor is behind a closed lid.
  security.pam.services.greetd.fprintAuth = lib.mkForce true;
  security.pam.services.greetd.rules.auth.fprintd.args = lib.mkForce [
    "timeout=5"
    "max-tries=1"
  ];
  security.pam.services.greetd.rules.auth.fprintd.order =
    config.security.pam.services.greetd.rules.auth.p11.order - 10;

  security.pam.services.greetd.rules.auth.lidGate =
    gate config.security.pam.services.greetd.fprintAuth
      (config.security.pam.services.greetd.rules.auth.fprintd.order - 1)
      lidClosed;

  # PIV + PIN; the card gate skips pcsc enumeration when no reader is present.
  security.pam.services.greetd.p11Auth = true;
  security.pam.services.greetd.rules.auth.p11.args = lib.mkForce [
    "${pkgs.opensc}/lib/opensc-pkcs11.so"
    "^[0-9]{8}$"
  ];
  security.pam.services.greetd.rules.auth.p11.control = lib.mkForce p11Control;
  security.pam.services.greetd.rules.auth.cardGate =
    gate config.security.pam.services.greetd.p11Auth
      (config.security.pam.services.greetd.rules.auth.p11.order - 1)
      ccidAbsent;

  # pam_p11 passes the PIN as authtok; keep it out of login.keyring.
  security.pam.services.greetd.enableGnomeKeyring = false;

  # The lock screen hardcodes `login` and drives fprintd over D-Bus, so no
  # pam_fprintd here. The text console gets PIN-or-password too.
  security.pam.services.login.p11Auth = true;
  # gnome-keyring splits `login` into two pam_unix prompts, breaking the
  # single-prompt invariant.
  security.pam.services.login.enableGnomeKeyring = lib.mkForce false;
  security.pam.services.login.rules.auth.p11.args = lib.mkForce [
    "${pkgs.opensc}/lib/opensc-pkcs11.so"
    "^[0-9]{8}$"
  ];
  security.pam.services.login.rules.auth.p11.control = lib.mkForce p11Control;
  security.pam.services.login.rules.auth.cardGate = gate config.security.pam.services.login.p11Auth (
    config.security.pam.services.login.rules.auth.p11.order - 1
  ) ccidAbsent;
}
