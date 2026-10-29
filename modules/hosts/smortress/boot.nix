# smortress's boot chain: systemd stage 1, lanzaboote, and the TPM plumbing the
# Clevis `sss` policy needs. Host-scoped because the machine's own sbctl keys
# and its Tang pin only exist here (see T2 in #250).
#
# Order matters: `sudo sbctl create-keys` must run before the first rebuild
# with this module. `autoGenerateKeys` is deliberately off so a missing key
# bundle fails the bootloader install instead of writing artifacts the
# firmware will not trust.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  # Scripted stage 1 is deprecated (removed in 26.11) and cannot express the
  # Clevis unit ordering. systemd stage 1 also gives the cryptsetup generator
  # the passphrase fallback when the Tang/TPM share cannot be satisfied.
  boot.initrd.systemd.enable = true;

  # The fTPM must be on in the firmware. Clevis orders its decrypt unit after
  # `tpm2.target`; without this the target never appears in the initrd and the
  # TPM share cannot unseal.
  security.tpm2.enable = true;
  boot.initrd.systemd.tpm2.enable = true;

  # Clevis sss: the Tang share and the TPM2 share (sealed to PCR 7) are both
  # required. The JWE is committed: it is ciphertext, and the identical token
  # already lives in the LUKS header. Stage 1 decrypts it to
  # /clevis-root/decrypted before systemd-cryptsetup@root; if either share
  # fails, systemd falls back to the passphrase slot.
  boot.initrd.clevis = {
    enable = true;
    useTang = true;
    devices.root.secretFile = ./root.jwe;
  };

  # Tang must be reachable before the Clevis unit runs. Match by MAC because
  # initrd link names are not guaranteed; the wired NIC is the only one with a
  # static address. Cable down or Tang down means a passphrase prompt.
  boot.initrd.systemd.network = {
    enable = true;
    # A dead link must not hide the passphrase prompt for two minutes.
    wait-online.timeout = 10;
    networks."10-lan" = {
      matchConfig.MACAddress = "3c:7c:3f:82:69:61";
      address = [ "10.0.0.125/24" ];
      # The initrd only needs the Tang route; drop the router advertisement so
      # no DHCPv6 address is acquired and then torn down at switch-root.
      networkConfig.IPv6AcceptRA = false;
    };
  };

  # Tang can accept the TCP connection and then stall; clevis's curl has no
  # overall timeout. Cap the unit so a wedged Tang reaches the passphrase
  # prompt instead of waiting out the initrd default.
  boot.initrd.systemd.services.cryptsetup-clevis-root.serviceConfig.TimeoutStartSec = "30s";
  # Defaults to false with systemd stage 1, which leaves the static address
  # (and no default route) in place across switch-root. NetworkManager then
  # sees the link as "connected (externally)" and never activates its DHCP
  # profile, so the tunnel and DNS never come up. Flush it and let stage 2
  # own the interface.
  boot.initrd.network.flushBeforeStage2 = true;

  # Belt and braces for the handoff: even with flushBeforeStage2 the initrd's
  # static address has survived switch-root, leaving NetworkManager with an
  # "externally connected" device and no DHCP activation (no default route,
  # no DNS). Define the wired profile declaratively and force it once NM and
  # the profile writer are up.
  networking.networkmanager.ensureProfiles.profiles.smortress-wired = {
    connection = {
      id = "smortress-wired";
      type = "ethernet";
      interface-name = "enp7s0";
      autoconnect = true;
      # Win over the auto-created "Wired connection 1" on the same link.
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
    # Only the initrd leaves the device "connected (externally)"; a normal
    # boot is a no-op. In that state, drop the device so the flush cannot strip
    # an active connection, then reconnect by profile so DHCP re-applies the
    # default route and DNS. Retry: failing here boots the box unreachable.
    script = ''
      set -eu
      nmcli=${pkgs.networkmanager}/bin/nmcli
      device="$($nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1; exit}')"
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
        sleep 2
      done
      exit 1
    '';
  };

  boot.initrd.availableKernelModules = [ "igc" ];

  # Lanzaboote replaces the systemd-boot module enabled by base.nix; the
  # firmware must load the signed stub for PCR 7 to measure our Secure Boot
  # policy rather than a bootloader we did not sign.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    # Lives in the LUKS root, never in the store or the repo. Back it up
    # before any reinstall: the firmware has these keys in `db`.
    pkiBundle = "/var/lib/sbctl";
    autoGenerateKeys.enable = false;
    # 1 GiB ESP: lzbt keeps a kernel + initrd per generation.
    configurationLimit = 10;
  };

  # sbctl signs and enrolls; clevis binds and inspects the LUKS token; the
  # tpm2 tools verify the PCR 7 value before and after the bind.
  environment.systemPackages = [
    pkgs.sbctl
    pkgs.clevis
    pkgs.tpm2-tools
  ];
}
