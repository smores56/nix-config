#!/usr/bin/env bash
# Configure a Raspberry Pi OS / Debian host as a Tang server for the smortress
# Clevis/LUKS unlock. Run on the Pi as root; copy it from the nix-config repo:
#
#   scp scripts/tang-pi.sh pi@<pi>:
#   ssh pi@<pi> 'sudo ./tang-pi.sh --allow <smortress-ip>/32'
#
# The script is intentionally Debian-specific. On NixOS, use the snippet it
# prints (services.tang + networking.firewall.allowedTCPPorts).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tang-pi.sh [--allow <cidr>]

Installs Tang on Raspberry Pi OS / Debian, enables tangd.socket, and prints the
Tang URL/port. --allow restricts the ufw rule to the given CIDR (recommended:
the smortress IP or LAN).

The Pi's /var/db/tang keys are sensitive: with the disk they can unlock it.
Keep the Pi patched and off the public internet.
EOF
}

allow_cidr=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow)
      if [ "$#" -lt 2 ]; then
        echo "error: --allow needs a CIDR" >&2
        usage >&2
        exit 2
      fi
      allow_cidr="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root (sudo ./tang-pi.sh --allow <cidr>)" >&2
  exit 1
fi

if [ -e /etc/NIXOS ]; then
  cat <<EOF
This host is NixOS. Add this to its configuration instead:

services.tang = {
  enable = true;
  listenStream = [ "7654" ];
  ipAddressAllow = [ "${allow_cidr:-192.168.1.0/24}" ];
};
networking.firewall.allowedTCPPorts = [ 7654 ];

Rebuild, then verify with: ss -ltn | grep 7654
EOF
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "error: this script currently supports Raspberry Pi OS / Debian only" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y tang

if ! systemctl list-unit-files tangd.socket | grep -q '^tangd.socket'; then
  echo "error: tang installed but tangd.socket is missing" >&2
  exit 1
fi

systemctl enable --now tangd.socket

# Tang defaults to 7654; read the actual socket if the package changed it.
listen=$(systemctl show -p Listen --value tangd.socket 2>/dev/null || true)
port=$(printf '%s\n' "$listen" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n1)
port=${port:-7654}

if [ -n "$allow_cidr" ]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow from "$allow_cidr" to any port "$port" proto tcp
  else
    printf 'Allow TCP %s from %s in the Pi firewall.\n' "$port" "$allow_cidr"
  fi
else
  printf 'WARNING: no --allow CIDR; restrict TCP %s to smortress/LAN.\n' "$port"
fi

ip=$(hostname -I 2>/dev/null | awk '{print $1}')
tang_url="http://${ip:-<pi-ip>}:$port"

cat <<EOF

Tang is listening on TCP $port.
Tang URL: $tang_url

On smortress (from the migration worktree):
  read -rsp 'LUKS passphrase: ' pass; echo
  printf '%s' "\$pass" | clevis encrypt tang '{"url":"$tang_url"}' > modules/hosts/smortress/cryptroot.jwe
  unset pass

Then add boot.initrd.clevis with cryptroot.secretFile = ./cryptroot.jwe and
boot.initrd.network.enable = true (see docs/manual-steps.md, "Tang Pi (Clevis)").

The Pi's /var/db/tang keys are sensitive. If the Pi is rebuilt, re-run the
clevis encrypt step with the LUKS passphrase. Keep the passphrase and printed
recovery key offline; do not expose Tang to the public internet.
EOF
