usage() {
  cat <<'EOF'
Usage: nix run .#key-restore -- <bundle.tar.gz> [--force] [--no-verify]
       nix run .#key-restore -- <bundle.tar.gz> --host-key [--force]

Restores the FIDO2 credential handles from a Bitwarden backup made
by `nix run .#key-backup`. Run it after `nix run .#bootstrap`.

With --host-key it restores only the host SSH key (the host's sops
identity) into secrets/hosts/<host>/etc/ssh/ in the current checkout.
Run that BEFORE `nix run .#install`, which delivers that directory.
EOF
}

umask 077
force=0
verify=1
host_key_mode=0
target_dir=""
sops_file=".sops.yaml"
archive=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) force=1 ;;
    --no-verify) verify=0 ;;
    --host-key) host_key_mode=1 ;;
    --target-dir)
      if [ "${KEY_BUNDLE_TEST:-0}" != 1 ]; then
        echo "key-restore: --target-dir is a test hook" >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "key-restore: --target-dir needs a path" >&2
        exit 1
      fi
      target_dir="$2"
      shift 2
      continue
      ;;
    --sops-file)
      if [ "${KEY_BUNDLE_TEST:-0}" != 1 ]; then
        echo "key-restore: --sops-file is a test hook" >&2
        exit 1
      fi
      if [ "$#" -lt 2 ]; then
        echo "key-restore: --sops-file needs a path" >&2
        exit 1
      fi
      sops_file="$2"
      shift 2
      continue
      ;;
    --pubkeys)
      if [ "${KEY_BUNDLE_TEST:-0}" != 1 ]; then
        echo "key-restore: --pubkeys is a test hook" >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ ! -r "$2" ]; then
        echo "key-restore: --pubkeys needs a readable path" >&2
        exit 1
      fi
      pubkeys="$2"
      shift 2
      continue
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --*)
      echo "key-restore: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "$archive" ]; then
        echo "key-restore: more than one bundle given" >&2
        exit 1
      fi
      archive="$1"
      ;;
  esac
  shift
done

if [ "$(id -u)" -eq 0 ]; then
  echo "key-restore: run as the user, not root" >&2
  exit 1
fi

if [ -z "$archive" ]; then
  usage >&2
  exit 1
fi
if [ ! -f "$archive" ]; then
  echo "key-restore: no such file: $archive" >&2
  exit 1
fi

if [ "$verify" -eq 1 ]; then
  if [ ! -f "$archive.sha256" ]; then
    echo "key-restore: missing $archive.sha256; pass --no-verify only if you checked the checksum yourself" >&2
    exit 1
  fi
  want="$(awk 'NR == 1 { print $1 }' "$archive.sha256")"
  got="$(sha256sum "$archive" | awk '{ print $1 }')"
  if [ "$want" != "$got" ]; then
    echo "key-restore: checksum mismatch for $archive" >&2
    exit 1
  fi
  echo "key-restore: checksum OK"
else
  echo "key-restore: skipping the outer checksum (--no-verify)" >&2
fi

if tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.(\/|$)/ { found=1 } END { exit !found }'; then
  echo "key-restore: the bundle contains unsafe paths; refusing" >&2
  exit 1
fi
if tar -tvzf "$archive" | awk 'substr($0, 1, 1) ~ /[lh]/ { found=1 } END { exit !found }'; then
  echo "key-restore: the bundle contains links; refusing" >&2
  exit 1
fi

stage="$(mktemp -d)"
recomputed="$stage.recomputed"
trap 'rm -rf "$stage" "$recomputed"' EXIT
tar --no-same-owner --no-same-permissions -C "$stage" -xzf "$archive"

if [ -n "$(find "$stage" -type l -print -quit)" ]; then
  echo "key-restore: the bundle contains symlinks; refusing" >&2
  exit 1
fi
for f in MANIFEST SHA256SUMS; do
  if [ ! -f "$stage/$f" ]; then
    echo "key-restore: $f is missing; not a key-backup bundle" >&2
    exit 1
  fi
done
(
  cd "$stage"
  find . -type f ! -name MANIFEST ! -name SHA256SUMS -print0 |
    sort -z | xargs -0 -r sha256sum >"$recomputed"
  if ! cmp -s "$recomputed" SHA256SUMS; then
    echo "key-restore: SHA256SUMS does not match the archive contents" >&2
    exit 1
  fi
)

host="$(sed -n 's/^host: //p' "$stage/MANIFEST")"
if [ "$(awk '/^host: /{ n++ } END { print n + 0 }' "$stage/MANIFEST")" -ne 1 ]; then
  echo "key-restore: the MANIFEST must hold exactly one host: line" >&2
  exit 1
fi
created="$(sed -n 's/^created: //p' "$stage/MANIFEST")"
missing="$(sed -n 's/^missing: //p' "$stage/MANIFEST")"
echo "key-restore: bundle from $host ($created)"

if [ "$host_key_mode" -eq 1 ]; then
  case "$host" in
    "" | */* | *..* | *[!A-Za-z0-9._-]*)
      echo "key-restore: the MANIFEST host name is invalid: '$host'" >&2
      exit 1
      ;;
  esac
  if [ -z "$target_dir" ] && [ ! -f flake.nix ]; then
    echo "key-restore: run --host-key from the nix-config checkout; install reads secrets/hosts/ from it" >&2
    exit 1
  fi
  if [ ! -r "$sops_file" ]; then
    echo "key-restore: cannot read $sops_file; run --host-key from the nix-config checkout" >&2
    exit 1
  fi
  src_dir="$stage/etc/ssh"
  if [ ! -f "$src_dir/ssh_host_ed25519_key" ]; then
    echo "key-restore: the bundle carries no host key; re-run key-backup on $host" >&2
    exit 1
  fi
  if ! private_pub="$(ssh-keygen -y -P "" -f "$src_dir/ssh_host_ed25519_key" 2>/dev/null)"; then
    echo "key-restore: the bundled host key is unreadable or passphrase-protected" >&2
    exit 1
  fi
  if [ -f "$src_dir/ssh_host_ed25519_key.pub" ]; then
    if [ "$(first_two <"$src_dir/ssh_host_ed25519_key.pub")" != "$(printf '%s\n' "$private_pub" | first_two)" ]; then
      echo "key-restore: the bundled private and public host keys do not match" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$private_pub" >"$stage/host-key.pub"
  recipient="$(ssh-to-age -i "$stage/host-key.pub")"
  expected="$(awk -v h="&$host" '$1 == "-" && $2 == h { print $3; exit }' "$sops_file")"
  if [ -z "$expected" ]; then
    echo "key-restore: $sops_file has no '&$host <age1...>' anchor; this key cannot be the host's sops identity" >&2
    exit 1
  fi
  if [ "$expected" != "$recipient" ]; then
    echo "key-restore: $host key derives $recipient, but $sops_file has $expected for &$host" >&2
    echo "key-restore: refusing to install a key the host's secrets are not encrypted to; re-key with nix run .#host-key" >&2
    exit 1
  fi
  dest="${target_dir:-secrets/hosts/$host/etc/ssh}"
  if [ "$force" -eq 0 ] && { [ -e "$dest/ssh_host_ed25519_key" ] || [ -e "$dest/ssh_host_ed25519_key.pub" ]; }; then
    echo "key-restore: $dest already exists; pass --force to replace it" >&2
    exit 1
  fi
  install -D -m 600 "$src_dir/ssh_host_ed25519_key" "$dest/ssh_host_ed25519_key"
  install -D -m 644 "$stage/host-key.pub" "$dest/ssh_host_ed25519_key.pub"
  cat <<EOF
key-restore: restored the host key for $host to $dest
key-restore: age recipient: $recipient

Next, install delivers it into the new root:
  nix run .#install -- $host root@<target-ip>
EOF
  exit 0
fi
current="$(uname -n)"
current="${current%%.*}"
if [ "$host" != "$current" ]; then
  echo "key-restore: bundle was made on $host; restoring handles on $current" >&2
fi
if [ -n "$missing" ] && [ "$missing" != none ]; then
  echo "key-restore: the backup was missing: $missing" >&2
fi

expected_pubkey() {
  awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$pubkeys"
}

# Refuse before writing if a handle exists or differs from the committed public half; a partial restore is unexplainable.
while IFS=$'\t' read -r key _; do
  [ -n "$key" ] || continue
  src="$stage/home/.config/ssh-sk/$key"
  [ -f "$src" ] || continue
  dest="$HOME/.config/ssh-sk/$key"
  if { [ -e "$dest" ] || [ -L "$dest" ]; } && [ "$force" -eq 0 ]; then
    echo "key-restore: $dest already exists; pass --force to replace it" >&2
    exit 1
  fi

  expected="$(expected_pubkey "$key")"
  if [ -z "$expected" ]; then
    echo "key-restore: $key has no committed public key in modules/lib/yubikey-keys.nix" >&2
    exit 1
  fi
  if ! got="$(ssh-keygen -y -P "" -f "$src" 2>/dev/null)"; then
    echo "key-restore: $key is passphrase-protected or unreadable" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$expected" | first_two)" != "$(printf '%s\n' "$got" | first_two)" ]; then
    echo "key-restore: $key does not match the committed public key" >&2
    exit 1
  fi
done <"$pubkeys"

# Reject a handle outside the committed map (the authoritative credential inventory).
for src in "$stage"/home/.config/ssh-sk/*/*; do
  [ -f "$src" ] || continue
  key="${src#"$stage/home/.config/ssh-sk/"}"
  if ! awk -F '\t' -v k="$key" '$1 == k { found=1 } END { exit !found }' "$pubkeys"; then
    echo "key-restore: $key is not a committed credential" >&2
    exit 1
  fi
done

if [ -f "$stage/home/dev/setup-yubikey.sh" ] && { [ -e "$HOME/dev/setup-yubikey.sh" ] || [ -L "$HOME/dev/setup-yubikey.sh" ]; } && [ "$force" -eq 0 ]; then
  echo "key-restore: $HOME/dev/setup-yubikey.sh already exists; pass --force to replace it" >&2
  exit 1
fi

installed=0
while IFS=$'\t' read -r key _; do
  [ -n "$key" ] || continue
  src="$stage/home/.config/ssh-sk/$key"
  [ -f "$src" ] || continue
  install -D -m 600 "$src" "$HOME/.config/ssh-sk/$key"
  installed=$((installed + 1))
done <"$pubkeys"
if [ "$installed" -eq 0 ]; then
  echo "key-restore: the bundle contains no handles" >&2
  exit 1
fi

if [ -f "$stage/home/dev/setup-yubikey.sh" ]; then
  install -D -m 600 "$stage/home/dev/setup-yubikey.sh" "$HOME/dev/setup-yubikey.sh"
  echo "key-restore: restored the enrollment script as data; review it, then chmod +x" >&2
fi

if [ "$(uname -s)" = Darwin ]; then
  cat <<EOF
key-restore: installed $installed handle(s) under $HOME/.config/ssh-sk

Next:
  home-manager switch
  launchctl kickstart -k gui/$(id -u)/org.nix-community.home.sudo-agent
  ssh smortress true
  ssh -t smortress sudo true

The admin age key stays on the laptops.
EOF
else
  cat <<EOF
key-restore: installed $installed handle(s) under $HOME/.config/ssh-sk

Next:
  home-manager switch        # if bootstrap has not already written the .pub files
  ssh smortress true         # one graphical PIN prompt on first use
  ssh -t smortress sudo true # one touch

The admin age key stays on the laptops.
EOF
fi

if [ "$(sed -n 's/^host-key: //p' "$stage/MANIFEST")" = yes ]; then
  echo "The host SSH key is in this bundle; restore it with --host-key before install."
else
  echo "This bundle carries no host key, so it cannot restore the host's sops identity."
fi
