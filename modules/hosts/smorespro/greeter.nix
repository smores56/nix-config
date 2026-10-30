# smorespro's greeter and lock-screen PAM: fingerprint, the YubiKey PIV PIN, and
# the account password, each attempted only when it can actually be used.
# Host-scoped because the recipe is tuned to this laptop's prompt order and its
# lid switch.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # pam_exec gives its command only the PAM environment (PAM_USER, PAM_SERVICE,
  # ...) and no PATH, so each probe owns its PATH (writeShellApplication) and no
  # command is resolved from the caller. A probe that cannot run exits 127, the
  # module returns SYSTEM_ERR, and the gate silently no-ops.
  #
  # Exit 0 means "lid closed": skip pam_fprintd. Any failure means "open", so a
  # broken probe costs the fingerprint path, never the password.
  lidClosed = pkgs.writeShellApplication {
    name = "pam-lid-closed";
    runtimeInputs = [
      config.systemd.package
      pkgs.gnugrep
    ];
    text = ''
      # logind is authoritative and readable before any session exists, so this
      # works at the greeter (root, no seat) as well as inside the session. The
      # timeout bounds a stalled logind, and a failure reads as "open". No
      # pipeline: grep -q could SIGPIPE busctl and pipefail would report the
      # lid as open in exactly the case this probe exists for.
      [ "$(busctl --system --timeout=1 get-property \
        org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager LidClosed)" = "b true" ]
    '';
  };

  # Exit 0 means "no CCID interface": skip pam_p11 so the password path is the
  # only prompt. This detects a READER, not a card; the PIV applet is a USB CCID
  # interface, and scanning sysfs costs ~9 ms where pcsc enumeration costs ~2 s
  # with no token - that 2 s is most of the wait this gate exists to remove.
  # Unreadable sysfs counts as absent. A reader without a matching certificate
  # is not a lockout: pam_p11 returns AUTHINFO_UNAVAIL, which the control below
  # falls through.
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

  # [success=1 default=ignore] skips exactly the next line on exit 0 and is
  # otherwise ignored, so the gate fails open. The order is anchored to the
  # module it guards, and `enable` ties the rule's lifetime to that module's:
  # success=1 skips whatever line follows, so a gate left behind when p11Auth or
  # fprintAuth is disabled would skip pam_unix instead.
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

  # pam_p11 grants, denies, or steps aside, never a second prompt.
  #   - success terminates: falling into pam_unix would ask again, which only
  #     noctalia 5.1.0 tolerates; its passwordSent guard (v5.3.0, PR #4294)
  #     turns a second prompt into a conversation error.
  #   - authinfo_unavail falls through: no matching certificate, a locked PIV,
  #     or pcscd down prompted for nothing, so the password stays reachable and
  #     is still the only prompt. This is what keeps a foreign reader, a
  #     rotated-out certificate, or an exhausted PIN from locking the machine.
  #   - anything else denies: a wrong PIN, or text that is not a PIN, stops
  #     here, so a typed password never reaches the card and never burns a PIV
  #     retry.
  p11Control = "[success=done authinfo_unavail=ignore default=die]";
in
{
  imports = [ inputs.noctalia-greeter.nixosModules.default ];

  services.displayManager.noctalia-greeter = {
    enable = true;
    # The module grants a passwordless appearance sync to listed users only;
    # every sync needs admin auth when the list is empty.
    passwordless-sync-users = [ ];
    # An empty submit is what starts the PAM conversation (and so fprintd);
    # without it the greeter refuses to submit until something is typed.
    settings.auth.allow_empty_password = true;
  };

  # Fingerprint first when the lid is open, so a touched sensor wins. The lid
  # gate is what skips it when the sensor is behind a closed lid - that ~5 s
  # wait is the whole reason for the gate. 5 s bounds an untouched sensor and
  # pam_fprintd honours it (MIN_TIMEOUT is 1 in 1.94.5).
  security.pam.services.greetd.fprintAuth = lib.mkForce config.fingerprint.enable;
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

  # PIV + PIN at the greeter: pam_p11 matches ~/.eid/authorized_certificates and
  # prompts only when a matching token is present. Without a key it returns
  # AUTHINFO_UNAVAIL, but the card gate has already skipped it in ~9 ms instead
  # of paying pcsc enumeration.
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

  # pam_p11 hands the PIN to PAM as the authtok, and greetd's default keyring
  # hook would then create/unlock login.keyring with an 8-digit secret. The
  # greeter is not the keyring's owner; keep it off.
  security.pam.services.greetd.enableGnomeKeyring = false;

  # The lock screen authenticates against `login` (Noctalia hardcodes it until
  # PR #4132 lands) and drives fprintd over D-Bus, so pam_fprintd stays off
  # here. The card gate removes the ~2 s pcsc enumeration this stack pays on
  # every password unlock, and the die keeps it to one prompt. Side effect: the
  # text console gets the same PIN-or-password behavior, but no PIV-less
  # lockout, because AUTHINFO_UNAVAIL falls through.
  security.pam.services.login.p11Auth = true;
  # gnome-keyring splits `login` into a two-prompt stack (an optional
  # pam_unix "unix-early", then a sufficient one with try_first_pass), so a
  # wrong password is asked twice. That breaks the single-prompt invariant this
  # stack depends on, and the lock screen's unprivileged helper cannot unlock a
  # password-derived keyring anyway (it never calls pam_open_session). The
  # greeter disables it for the same reason (pam_p11 hands it the PIN); the
  # daemon stays enabled for D-Bus users.
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
