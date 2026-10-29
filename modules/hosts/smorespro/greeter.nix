# smorespro's greeter: noctalia-greeter over greetd, with the YubiKey PIV PIN as
# one of the prompts. Host-scoped because the PAM recipe below is tuned to this
# laptop's prompt order.
{
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
  };

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
}
