{ config, lib, ... }:
{
  config = lib.mkIf config.dotfiles.fingerprint {
    # Goodix 27c6:609c is handled by libfprint's native goodixmoc driver; no
    # proprietary TOD package is needed.
    services.fprintd.enable = true;

    # services.fprintd.enable defaults fprintAuth to true on every PAM service.
    # Fingerprint has no user-attention guarantee (CVE-2024-37408), so keep it
    # off sudo/su. The lock screen drives fprintd over D-Bus, not PAM.
    security.pam.services.sudo.fprintAuth = false;
    security.pam.services.su.fprintAuth = false;
  };
}
