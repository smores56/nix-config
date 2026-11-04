umask 077

allow_incomplete=0
host_key_src="/etc/ssh/ssh_host_ed25519_key"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-incomplete) allow_incomplete=1; shift ;;
    # The live key is authoritative; the checkout copy is only what
    # `install` reads. Tests and odd layouts can point elsewhere.
    --host-key-path)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "key-backup: --host-key-path needs a path" >&2
        exit 1
      fi
      host_key_src="$2"
      shift 2
      continue
      ;;
    --no-host-key) host_key_src=""; shift ;;
    # Test hook: the build embeds the committed map.
    --pubkeys)
      if [ "${KEY_BUNDLE_TEST:-0}" != 1 ]; then
        echo "key-backup: --pubkeys is a test hook" >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ ! -r "$2" ]; then
        echo "key-backup: --pubkeys needs a readable path" >&2
        exit 1
      fi
      pubkeys="$2"
      shift 2
      continue
      ;;
    -h | --help)
      echo "Usage: nix run .#key-backup [--allow-incomplete] [--host-key-path <path>] [--no-host-key]"
      echo "  The host SSH key under /etc/ssh is archived by default (one sudo prompt)."
      echo "  --no-host-key skips it, for a machine that has no sops identity of its own."
      exit 0
      ;;
    *)
      echo "key-backup: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  echo "key-backup: run as the user who owns the handles, not root" >&2
  exit 1
fi

host="$(uname -n)"
host="${host%%.*}"

# The host key can only be validated against the committed anchors.
# Without this file the check would vanish silently, leaving a bundle
# that looks complete but carries the wrong sops identity.
if [ -n "$host_key_src" ] && [ ! -f .sops.yaml ]; then
  echo "key-backup: run this from the nix-config checkout: .sops.yaml is needed to prove the live host key is the identity this host's secrets are encrypted to" >&2
  exit 1
fi
if [ -z "$host_key_src" ] && [ -f .sops.yaml ] \
  && [ -n "$(awk -v h="&$host" '$1 == "-" && $2 == h { print $3; exit }' .sops.yaml)" ]; then
  echo "key-backup: error: .sops.yaml binds &$host to a key, so this host does need its host key; drop --no-host-key" >&2
  exit 1
fi
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/key-backup"
install -d -m 700 "$state_dir"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/home"


handles=0
missing=()
while IFS=$'\t' read -r key expected; do
  [ -n "$key" ] || continue
  src="$HOME/.config/ssh-sk/$key"
  if [ ! -f "$src" ]; then
    missing+=("$key")
    continue
  fi

  if [ -z "$expected" ]; then
    echo "key-backup: $key has no committed public key in modules/lib/yubikey-keys.nix" >&2
    exit 1
  fi
  if ! got="$(ssh-keygen -y -P "" -f "$src" 2>/dev/null)"; then
    echo "key-backup: $key is passphrase-protected or unreadable; the agents expect an empty file passphrase" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$expected" | first_two)" != "$(printf '%s\n' "$got" | first_two)" ]; then
    echo "key-backup: $key does not match the committed public key; re-enroll it" >&2
    exit 1
  fi

  install -D -m 600 "$src" "$stage/home/.config/ssh-sk/$key"
  handles=$((handles + 1))
done <"$pubkeys"

for src in "$HOME"/.config/ssh-sk/*/sudo; do
  [ -f "$src" ] || continue
  key="${src#"$HOME/.config/ssh-sk/"}"
  if ! awk -F '\t' -v k="$key" '$1 == k { found=1 } END { exit !found }' "$pubkeys"; then
    echo "key-backup: WARNING: $key is on disk but not in modules/lib/yubikey-keys.nix; not backed up" >&2
  fi
done

# The host SSH key is the host's sops identity and `install` delivers
# it from secrets/hosts/<host>/. Read the live key, never the checkout
# copy: /etc/ssh is 0600 root, so one sudo read is expected. A missing
# host key is a hard failure — a wipe destroys the only copy, and the
# handle path below is recoverable where this one is not.
host_key_state=no
host_key_recipient=""
if [ -n "$host_key_src" ]; then
  mkdir -p "$stage/etc/ssh"
  src_key="$stage/etc/ssh/ssh_host_ed25519_key"
  read_ok=1
  if [ -r "$host_key_src" ]; then
    cp "$host_key_src" "$src_key" || read_ok=0
  elif [ -t 0 ]; then
    # shellcheck disable=SC2024 # the redirect writes as the user on purpose; sudo only reads
    sudo cat "$host_key_src" >"$src_key" || read_ok=0
  else
    # shellcheck disable=SC2024
    sudo -n cat "$host_key_src" >"$src_key" || read_ok=0
  fi
  if [ "$read_ok" -eq 1 ] && ssh-keygen -y -P "" -f "$src_key" >/dev/null 2>&1; then
    chmod 600 "$src_key"
    ssh-keygen -y -P "" -f "$src_key" >"$src_key.pub"
    chmod 644 "$src_key.pub"
    host_key_recipient="$(ssh-to-age -i "$src_key.pub")"
    host_key_state=yes
  else
    rm -rf "${stage:?}/etc"
    echo "key-backup: cannot read a usable private key at $host_key_src" >&2
    echo "key-backup: a wipe would destroy the host's sops identity, so nothing was written" >&2
    echo "key-backup: run this from an interactive shell so sudo can prompt" >&2
    exit 1
  fi
  want_anchor="$(awk -v h="&$host" '$1 == "-" && $2 == h { print $3; exit }' .sops.yaml)"
  if [ -z "$want_anchor" ]; then
    echo "key-backup: error: .sops.yaml has no '&$host <age1...>' anchor" >&2
    echo "key-backup: add it and run sops updatekeys, or restore the key that anchor names" >&2
    exit 1
  fi
  if [ "$want_anchor" != "$host_key_recipient" ]; then
    echo "key-backup: error: $host_key_src derives $host_key_recipient, but .sops.yaml has $want_anchor for &$host" >&2
    echo "key-backup: this host could not decrypt its secrets after a restore; fix the key before wiping" >&2
    exit 1
  fi
fi

if [ "$handles" -eq 0 ] && [ "$host_key_state" = no ]; then
  echo "key-backup: no FIDO2 handles under $HOME/.config/ssh-sk" >&2
  echo "key-backup: run this on a laptop where the keys are enrolled and sudo works" >&2
  exit 1
fi
if [ "$handles" -eq 0 ]; then
  echo "key-backup: no FIDO2 handles here; archiving the host key only" >&2
fi

map_count="$(awk -F '\t' 'NF && $1 != "" { n++ } END { print n + 0 }' "$pubkeys")"
if [ "$handles" -gt 0 ] && [ "$handles" -lt "$map_count" ] && [ "$allow_incomplete" -eq 0 ]; then
  echo "key-backup: incomplete: $handles of $map_count committed handles" >&2
  echo "key-backup: fix the missing keys, or pass --allow-incomplete to archive a partial set" >&2
  exit 1
fi

# The enrollment script is untracked today, so this bundle is its only
# copy besides the machine being wiped. Keep it non-executable and
# review it before running after a restore; it may carry operator
# choices the repo should own.

script_state=no
if [ -f "$HOME/dev/setup-yubikey.sh" ]; then
  install -D -m 600 "$HOME/dev/setup-yubikey.sh" "$stage/home/dev/setup-yubikey.sh"
  script_state=yes
fi

{
  printf 'host: %s\n' "$host"
  printf 'created: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source-home: %s\n' "$HOME"
  printf 'handles: %s\n' "$handles"
  printf 'setup-script: %s\n' "$script_state"
  printf 'host-key: %s\n' "$host_key_state"
  if [ "$host_key_state" = yes ]; then
    printf 'host-key-recipient: %s\n' "$host_key_recipient"
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'missing: %s\n' "${missing[*]}"
  else
    printf 'missing: none\n'
  fi
  printf '\n'
  if [ "$host_key_state" = yes ]; then
    printf 'Contents: FIDO2 credential handles and the host SSH key (the\n'
    printf 'host sops identity). The FIDO2 private halves stay on each\n'
    printf 'YubiKey and cannot be exported. No admin age key, PIN, or PUK\n'
    printf 'is in this bundle; the enrollment script is data, so review it.\n'
  else
    printf 'Contents: FIDO2 credential handles only (--no-host-key was used).\n'
    printf 'The private halves stay on each YubiKey and cannot be exported.\n'
    printf 'No admin age key, PIN, or PUK is in this bundle.\n'
  fi
} >"$stage/MANIFEST"

(
  cd "$stage"
  find . -type f ! -name MANIFEST ! -name SHA256SUMS -print0 |
    sort -z | xargs -0 -r sha256sum
) >"$stage/SHA256SUMS"

archive="$state_dir/${host}-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -C "$stage" -czf "$archive" .
tar -tzf "$archive" >/dev/null
chmod 600 "$archive"
sha256sum "$archive" | awk '{ print $1 }' >"$archive.sha256"
chmod 600 "$archive.sha256"

if [ "${#missing[@]}" -gt 0 ]; then
  echo "key-backup: WARNING: incomplete backup; missing: ${missing[*]}" >&2
  echo "key-backup: fix the missing handles before you wipe the machine" >&2
fi

if command -v shred >/dev/null 2>&1; then
  remove="shred -u"
else
  remove="rm -P"
fi

cat <<EOF
key-backup: wrote $archive
key-backup: checksum $archive.sha256
key-backup: handles: $handles, setup script: $script_state, host key: $host_key_state
EOF

if [ "$host_key_state" = yes ]; then
  printf 'key-backup: host key age recipient: %s\n' "$host_key_recipient"
  printf 'key-backup: it must match &%s in .sops.yaml\n' "$host"
fi

cat <<EOF

Upload both files to Bitwarden:
  1. Create a Note item named "nix-config restore bundle — $host"
     in the vault that holds recovery material.
  2. Attach the .tar.gz and the .sha256, then save.
  3. Once Pass shows them, remove the local copies:
       $remove "$archive" "$archive.sha256"

Bitwarden encrypts attachments end-to-end; the archive itself is not
separately encrypted. Using a restored handle needs the physical YubiKey
and a touch for sudo.
EOF

if [ "$host_key_state" = yes ]; then
  cat <<EOF

The archive also holds the host's SSH private key, i.e. its sops identity:
anyone who can read this Pass item can impersonate $host and decrypt its
sops secrets. The admin age key (~/.config/sops/keys.age) stays separate.

Before wiping or reinstalling, put the host key where install reads it:
  nix run .#key-restore -- <downloaded-bundle.tar.gz> --host-key
EOF
else
  cat <<EOF

This bundle has no host key, so it cannot restore the host's sops
identity; an operator checkout copy or nix run .#host-key is the only
path for that.
EOF
fi

cat <<EOF

After bootstrap, restore the handles on the new machine:
  nix run .#key-restore -- <downloaded-bundle.tar.gz>
EOF
