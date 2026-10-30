# smorespro's greeter and lock-screen PAM: fingerprint, the YubiKey PIV PIN, and
# the account password. Host-scoped because the PAM recipe below is tuned to
# this laptop's prompt order.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.noctalia-greeter.nixosModules.default ];

  services.displayManager.noctalia-greeter = {
    enable = true;
    # The module grants a passwordless appearance sync to listed users only;
    # every sync needs admin auth when the list is empty.
    passwordless-sync-users = [ ];
    # pam_fprintd only runs after a submit; let it start before any typing.
    settings.auth.allow_empty_password = true;
  };

  # Fingerprint is tried first, so a touched sensor wins; a key with no touch
  # falls through to the PIN, and no key falls through to the password. The
  # 5s timeout bounds an untouched sensor (or a closed lid) before PIV rather
  # than pam_fprintd's 30s default.
  security.pam.services.greetd.fprintAuth = lib.mkForce true;
  security.pam.services.greetd.rules.auth.fprintd.args = lib.mkForce [
    "timeout=5"
    "max-tries=1"
  ];
  security.pam.services.greetd.rules.auth.fprintd.order =
    config.security.pam.services.greetd.rules.auth.p11.order - 10;

  # PIV + PIN at the greeter: pam_p11 matches ~/.eid/authorized_certificates and
  # becomes the first prompt when a key is in the reader. The two settings must
  # stay together — pam_p11 without its second argument forwards any typed text
  # to the card, and eight wrong PINs exhaust the off-site PUK. The regex is
  # applied to the typed value, so a password typed at the PIN prompt is
  # rejected locally instead of burning a retry. Without a key pam_p11 returns
  # AUTHINFO_UNAVAIL and greetd falls through to the password prompt.
  security.pam.services.greetd.p11Auth = true;
  security.pam.services.greetd.rules.auth.p11.args = lib.mkForce [
    "${pkgs.opensc}/lib/opensc-pkcs11.so"
    "^[0-9]{8}$"
  ];

  # pam_p11 hands the PIN to PAM as the authtok, and greetd's default keyring
  # hook would then create/unlock login.keyring with an 8-digit secret. The
  # greeter is not the keyring's owner; keep it off.
  security.pam.services.greetd.enableGnomeKeyring = false;

  # The lock screen authenticates against `login`, and the pinned noctalia
  # (5.1.0) answers every PAM prompt with the typed text, so the same PIV
  # recipe works there. A password is refused locally by the digit regex and
  # then reaches pam_unix through try_first_pass; no card is
  # PAM_AUTHINFO_UNAVAIL. Side effect: the text console gets the same PIN-or-
  # password behavior. Do not upgrade noctalia past 5.4.0 without carrying the
  # passwordSent patch (it would answer only the first prompt and silently
  # disable PIV unlock).
  security.pam.services.login.p11Auth = true;
  security.pam.services.login.rules.auth.p11.args = lib.mkForce [
    "${pkgs.opensc}/lib/opensc-pkcs11.so"
    "^[0-9]{8}$"
  ];
}
