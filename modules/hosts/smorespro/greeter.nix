# smorespro PAM: the greeter asks for the password only; the lock screen and the
# text console accept a YubiKey PIV PIN or the password, and the lock screen also
# drives the fingerprint reader over D-Bus.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
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
    # Sync only writes wallpaper, palette, font and layout; letting the user run
    # it without a polkit prompt keeps the login screen matching the lock screen.
    passwordless-sync-users = [ config.machine.username ];
    settings = {
      # Open on the password step instead of a user picker.
      user.default = config.machine.username;
      session.default = "Niri";
      # The lock screen has no session or scheme picker; neither does login.
      appearance.scheme_selector_position = "hidden";
      clock = {
        time_format = "{:%-I:%M %p}";
        date_format = "%a, %b %d";
      };
      # An empty submit must not start a PAM conversation.
      auth.allow_empty_password = false;
    };
  };

  # Login is password-only: fprintd.nix already disables pam_fprintd on greetd,
  # and PIV stays off because a typed password must never burn a PIV retry.
  security.pam.services.greetd.p11Auth = false;
  # greetd inherits gnome-keyring's enable, which inserts an early optional
  # pam_unix and a second prompt. Keep the greeter to one password prompt.
  security.pam.services.greetd.enableGnomeKeyring = false;

  # The lock screen hardcodes `login` and drives fprintd over D-Bus, so no
  # pam_fprintd here. PIN-or-password here serves the lock screen and the text
  # console; `login` cannot be split between them.
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
