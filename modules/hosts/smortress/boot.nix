# smortress's boot chain: systemd stage 1, lanzaboote, and the TPM plumbing the
# Clevis `sss` policy needs. Run `sudo sbctl create-keys` before the first rebuild;
# `autoGenerateKeys` is off so a missing key bundle fails the install instead of
# writing artifacts the firmware will not trust.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  # Scripted stage 1 cannot express the Clevis unit ordering; systemd stage 1 also
  # falls back to the passphrase when the Tang/TPM share fails.
  boot.initrd.systemd.enable = true;

  # Clevis orders its decrypt unit after `tpm2.target`, which only exists with this.
  security.tpm2.enable = true;
  boot.initrd.systemd.tpm2.enable = true;

  # Tang and TPM2 (PCR 7) shares are both required. The JWE is ciphertext and already
  # in the LUKS header, so it is committed; either share failing falls back to the passphrase.
  boot.initrd.clevis = {
    enable = true;
    useTang = true;
    devices.root.secretFile = ./root.jwe;
  };

  # Matched by MAC because initrd link names are not stable.
  boot.initrd.systemd.network = {
    enable = true;
    # A dead link must not hide the passphrase prompt.
    wait-online.timeout = 10;
    networks."10-lan" = {
      matchConfig.MACAddress = "3c:7c:3f:82:69:61";
      address = [ "10.0.0.125/24" ];
      # No DHCPv6 address acquired then torn down at switch-root.
      networkConfig.IPv6AcceptRA = false;
    };
  };

  # clevis's curl has no overall timeout; a wedged Tang must reach the passphrase prompt.
  boot.initrd.systemd.services.cryptsetup-clevis-root.serviceConfig.TimeoutStartSec = "30s";
  # Otherwise the initrd's static address survives switch-root and NetworkManager
  # reports "connected (externally)" without running DHCP.
  boot.initrd.network.flushBeforeStage2 = true;

  # Belt and braces: the static address has survived switch-root even with
  # flushBeforeStage2, so declare the wired profile and force it.
  networking.networkmanager.ensureProfiles.profiles.smortress-wired = {
    connection = {
      id = "smortress-wired";
      type = "ethernet";
      interface-name = "enp7s0";
      autoconnect = true;
      # Beats the auto-created "Wired connection 1".
      autoconnect-priority = 10;
    };
    ipv4.method = "auto";
    ipv6.method = "auto";
  };

  systemd.services.networkmanager-reclaim-wired = {
    description = "Reclaim the wired link from the initrd's static config";
    wantedBy = [ "multi-user.target" ];
    # Consumers of network-online must not run against the un-reclaimed link.
    before = [ "NetworkManager-wait-online.service" ];
    after = [
      "NetworkManager.service"
      "NetworkManager-ensure-profiles.service"
    ];
    wants = [
      "NetworkManager.service"
      "NetworkManager-ensure-profiles.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 60;
    };
    # No-op unless the initrd left the device "connected (externally)". Retry: failing
    # here boots the box unreachable.
    script = ''
      set -eu
      nmcli=${pkgs.networkmanager}/bin/nmcli
      device="$($nmcli -t -f DEVICE,TYPE device status | ${pkgs.gawk}/bin/awk -F: '$2=="ethernet"{print $1; exit}')"
      [ -n "$device" ] || exit 0
      state="$($nmcli -t -f GENERAL.STATE device show "$device" 2>/dev/null || true)"
      case "$state" in
        *"(externally)"*) ;;
        *) exit 0 ;;
      esac
      $nmcli device disconnect "$device" || true
      ${pkgs.iproute2}/bin/ip addr flush dev "$device" || true
      for attempt in 1 2 3 4 5; do
        if $nmcli connection up smortress-wired; then
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done
      exit 1
    '';
  };

  boot.initrd.availableKernelModules = [ "igc" ];

  # Replaces systemd-boot (base.nix); PCR 7 needs the signed stub.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    # Lives in the LUKS root; back it up before any reinstall (the firmware has these keys in `db`).
    pkiBundle = "/var/lib/sbctl";
    autoGenerateKeys.enable = false;
    # 1 GiB ESP: lzbt keeps a kernel + initrd per generation.
    configurationLimit = 10;
  };

  environment.systemPackages = [
    pkgs.sbctl
    pkgs.clevis
    pkgs.tpm2-tools
  ];
}
