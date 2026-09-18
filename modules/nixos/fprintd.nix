{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  # The Goodix reader's xHCI host controller sometimes fails to re-enumerate it
  # after suspend/resume (Framework issue #102), leaving the device off the bus
  # until the controller is reset. Cache the host controller at boot, then after
  # each wake reset it only if the reader is actually missing.
  resumeScript = pkgs.writeShellApplication {
    name = "framework-fprint-resume";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      kmod
      systemd
      util-linux
    ];
    text = ''
      STATE=/run/fprintd-reader-controller
      TAG=fp-rebind
      log() { logger -t "$TAG" "$*"; }

      # Echo the PCI function of the fingerprint reader's host controller, or
      # nothing when the reader is not currently on the bus.
      find_controller() {
        local dev vendor product
        for dev in /sys/bus/usb/devices/*/; do
          [ -r "$dev/idVendor" ] || continue
          vendor=$(cat "$dev/idVendor")
          [ "$vendor" = "27c6" ] || continue
          product=$(cat "$dev/product" 2>/dev/null || true)
          case "$product" in
            *[Ff]ingerprint*)
              readlink -f "$dev" \
                | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' \
                | tail -1 || true
              return 0
              ;;
          esac
        done
        return 0
      }

      cache() {
        local pci
        pci=$(find_controller)
        if [ -n "$pci" ]; then
          printf '%s\n' "$pci" > "$STATE"
          log "cached fingerprint host controller $pci"
        else
          log "fingerprint reader not present; nothing cached"
        fi
      }

      restore() {
        local pci driver
        sleep 2
        if [ -n "$(find_controller)" ]; then
          cache
          log "reader present, no action needed"
          return 0
        fi

        pci=""
        if [ -r "$STATE" ]; then pci=$(cat "$STATE"); fi

        if [ -n "$pci" ] && [ -d "/sys/bus/pci/devices/$pci" ]; then
          driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci/driver" 2>/dev/null || echo xhci_hcd)")
          log "reader missing, resetting controller $pci via $driver"
          if ! echo "$pci" > "/sys/bus/pci/drivers/$driver/unbind" 2>/dev/null; then
            log "ERROR: unbind of $pci failed"
          elif ! { sleep 1; echo "$pci" > "/sys/bus/pci/drivers/$driver/bind"; } 2>/dev/null; then
            log "ERROR: rebind of $pci failed"
          fi
        else
          log "reader missing with no cached controller; cycling xhci_pci"
          modprobe -r xhci_pci || true
          modprobe xhci_pci || true
        fi

        sleep 2
        systemctl try-restart fprintd.service || true
        if [ -n "$(find_controller)" ]; then
          cache
          log "SUCCESS: reader restored"
        else
          log "WARNING: reader still missing"
        fi
      }

      case "''${1:-}" in
        cache) cache ;;
        restore) restore ;;
        *) echo "usage: $0 {cache|restore}" >&2; exit 2 ;;
      esac
    '';
  };
in
{
  config = lib.mkIf cfg.fingerprint {
    # Goodix 27c6:609c is handled by libfprint's native goodixmoc driver; no
    # proprietary TOD package is needed.
    services.fprintd.enable = true;

    # services.fprintd.enable defaults fprintAuth to true on every PAM service.
    # Fingerprint has no user-attention guarantee (CVE-2024-37408), so keep it
    # off sudo/su. The lock screen drives fprintd over D-Bus, not PAM.
    security.pam.services.sudo.fprintAuth = false;
    security.pam.services.su.fprintAuth = false;

    systemd.services.fprintd-reader-cache = {
      description = "Cache the fingerprint reader's USB host controller";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${resumeScript}/bin/framework-fprint-resume cache";
      };
    };

    systemd.services.fprintd-reader-restore = {
      description = "Restore the fingerprint reader after resume";
      after = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      wantedBy = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${resumeScript}/bin/framework-fprint-resume restore";
      };
    };
  };
}
