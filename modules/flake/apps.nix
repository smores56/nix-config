{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };

      # Runs the checked-in script with the tools it needs on PATH; the script
      # is idempotent and clones the repo to $HOME/code itself.
      bootstrap = pkgs.writeShellApplication {
        name = "bootstrap";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          findutils
          gawk
          git
          gnugrep
          openssh
          gh
        ];
        text = ''
          exec ${inputs.self}/bootstrap.sh "$@"
        '';
      };

      # Installs NixOS on a blank machine over SSH (disko + nixos-anywhere),
      # writing the generated hardware config back into the checkout. Run from
      # the checkout; the host needs modules/hosts/<host>/{meta.nix,disko.nix}.
      install = pkgs.writeShellApplication {
        name = "install";
        runtimeInputs = [
          pkgs.git
          pkgs.gnugrep
          pkgs.nixos-anywhere
          pkgs.sops
          pkgs.ssh-to-age
        ];
        text = ''
          usage() {
            cat <<'EOF'
          Usage: nix run .#install -- <host> <target-host> [extra nixos-anywhere args]

          Install NixOS on a blank machine over SSH using disko + nixos-anywhere.
          Run from the nix-config checkout: the generated hardware config is
          written to modules/hosts/<host>/hardware.nix.

            <host>         host directory name, e.g. smortress
            <target-host>  the blank machine, e.g. root@192.168.1.50

          The host must already have modules/hosts/<host>/{meta.nix,disko.nix}
          committed. See AGENTS.md.
          EOF
          }

          if [ "$#" -lt 2 ]; then
            usage >&2
            exit 1
          fi

          host="$1"
          target="$2"
          shift 2

          case "$host" in
            "" | */* | *..*)
              echo "error: invalid host name: $host" >&2
              exit 1
              ;;
          esac

          if [ ! -f flake.nix ]; then
            echo "error: run from the nix-config checkout (no flake.nix in $(pwd))" >&2
            exit 1
          fi

          host_dir="modules/hosts/$host"
          for f in meta.nix disko.nix; do
            if [ ! -f "$host_dir/$f" ]; then
              echo "error: $host_dir/$f is missing — create modules/hosts/$host/ first (see AGENTS.md)" >&2
              exit 1
            fi
            git ls-files --error-unmatch "$host_dir/$f" >/dev/null 2>&1 \
              || { echo "error: $host_dir/$f is not tracked by git — commit it (flakes only see tracked files)" >&2; exit 1; }
          done

          hardware="$host_dir/hardware.nix"

          # A pre-generated host key (secrets/hosts/<host>/, gitignored) is
          # delivered before first boot so sops-nix can decrypt that host's
          # secrets. Generate it with `nix run .#host-key -- <host>`.
          extra_files=()
          if [ -d "secrets/hosts/$host" ]; then
            echo "Delivering secrets/hosts/$host into the new root"
            extra_files=(--extra-files "secrets/hosts/$host")
            key_pub="secrets/hosts/$host/etc/ssh/ssh_host_ed25519_key.pub"
            key_priv="secrets/hosts/$host/etc/ssh/ssh_host_ed25519_key"
            if [ -f "$key_pub" ]; then
              recipient="$(ssh-to-age -i "$key_pub")"
              if grep -qF "$recipient" .sops.yaml; then
                echo "Host key recipient ''${recipient} is in .sops.yaml"
              else
                echo "warning: host key recipient ''${recipient} is NOT in .sops.yaml — sops secrets will not decrypt on first boot" >&2
              fi
              # Strongest preflight: prove the delivered key actually decrypts
              # this host's secrets. A recipient can appear in .sops.yaml without
              # being bound to a rule for secrets/<host>.yaml, and a regenerated
              # key encrypts to a recipient the host cannot use.
              if [ -f "secrets/$host.yaml" ]; then
                # Blank the admin-key command: sops runs it eagerly even though
                # this preflight supplies the host key, and it would otherwise
                # prompt for (or fail to find) the operator's passphrase here.
                if SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$key_priv")" \
                  SOPS_AGE_KEY_CMD= \
                  sops --decrypt "secrets/$host.yaml" >/dev/null 2>&1; then
                  echo "Host key decrypts secrets/$host.yaml"
                else
                  echo "error: the delivered host key cannot decrypt secrets/$host.yaml — fix .sops.yaml and run 'sops updatekeys secrets/$host.yaml' before installing" >&2
                  exit 1
                fi
              fi
            fi
          else
            echo "warning: secrets/hosts/$host is missing — no host key will be delivered; sops secrets will not decrypt on first boot (run: nix run .#host-key -- $host)" >&2
          fi

          nixos-anywhere \
            --flake ".#$host" \
            --target-host "$target" \
            --generate-hardware-config nixos-generate-config "$hardware" \
            "''${extra_files[@]}" \
            "$@"

          echo
          echo "Installed $host. Commit the generated hardware config:"
          echo "  git add $hardware && git commit -m 'Add $host hardware config'"
        '';
      };

      # Generates the pre-generated SSH host key a blank machine boots with
      # (`install` delivers it via --extra-files) and prints its sops age
      # recipient. The key lives under the gitignored secrets/hosts/<host>/.
      host-key = pkgs.writeShellApplication {
        name = "host-key";
        runtimeInputs = with pkgs; [
          coreutils
          openssh
          ssh-to-age
        ];
        text = ''
          if [ "$#" -ne 1 ]; then
            echo "usage: nix run .#host-key -- <host>" >&2
            exit 1
          fi

          host="$1"

          case "$host" in
            "" | */* | *..*)
              echo "error: invalid host name: $host" >&2
              exit 1
              ;;
          esac

          if [ ! -f flake.nix ]; then
            echo "error: run from the nix-config checkout (no flake.nix in $(pwd))" >&2
            exit 1
          fi

          dir="secrets/hosts/$host/etc/ssh"
          key="$dir/ssh_host_ed25519_key"

          mkdir -p "$dir"
          if [ -f "$key" ]; then
            echo "Using existing $key"
          else
            ssh-keygen -q -t ed25519 -N "" -C "$host host key" -f "$key"
            echo "Generated $key"
          fi

          recipient="$(ssh-to-age -i "$key.pub")"

          echo
          echo "age recipient: $recipient"
          echo "Add it to .sops.yaml as &$host, then re-encrypt that host's secrets:"
          echo "  sops updatekeys secrets/$host.yaml"
        '';
      };

      # Packages the FIDO2 credential handles (the files that make a YubiKey
      # usable for sudo/signing) so a wiped machine can be rebuilt without
      # re-enrolling the keys. PIV private keys are generated on the token and
      # cannot be exported, so they are not part of any backup.
      yubikeyKeys = import ../lib/yubikey-keys.nix;
      yubikeyPubkeys = pkgs.writeText "yubikey-pubkeys" (
        pkgs.lib.concatMapStrings (k: "${k.key}\t${k.pubkey}\n") (yubikeyKeys.signing ++ yubikeyKeys.sudo)
      );

      key-backup = pkgs.writeShellApplication {
        name = "key-backup";
        runtimeInputs = with pkgs; [
          coreutils
          findutils
          gawk
          gnutar
          gzip
          openssh
        ];
        text = ''
          umask 077

          pubkeys="${yubikeyPubkeys}"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --pubkeys)
                if [ "$#" -lt 2 ]; then
                  echo "key-backup: --pubkeys needs a path" >&2
                  exit 1
                fi
                pubkeys="$2"
                shift 2
                continue
                ;;
              -h | --help)
                echo "Usage: nix run .#key-backup"
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
          host="''${host%%.*}"
          state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/key-backup"
          install -d -m 700 "$state_dir"

          stage="$(mktemp -d)"
          trap 'rm -rf "$stage"' EXIT
          mkdir -p "$stage/home"

          expected_pubkey() {
            awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$pubkeys"
          }
          first_two() {
            awk '{ print $1" "$2 }'
          }

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

          if [ "$handles" -eq 0 ]; then
            echo "key-backup: no FIDO2 handles under $HOME/.config/ssh-sk" >&2
            echo "key-backup: run this on a laptop where the keys are enrolled and yk-login works" >&2
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
            if [ "''${#missing[@]}" -gt 0 ]; then
              printf 'missing: %s\n' "''${missing[*]}"
            else
              printf 'missing: none\n'
            fi
            printf '\n'
            printf 'FIDO2 credential handles only: the private half stays on each\n'
            printf 'YubiKey and cannot be exported. No host key, admin age key, PIN,\n'
            printf 'or PUK is included.\n'
          } >"$stage/MANIFEST"

          (
            cd "$stage"
            find home -type f -print0 | sort -z | xargs -0 sha256sum
          ) >"$stage/SHA256SUMS"

          archive="$state_dir/$host-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
          tar -C "$stage" -czf "$archive" .
          chmod 600 "$archive"
          sha256sum "$archive" | awk '{ print $1 }' >"$archive.sha256"
          chmod 600 "$archive.sha256"

          if [ "''${#missing[@]}" -gt 0 ]; then
            echo "key-backup: WARNING: incomplete backup; missing: ''${missing[*]}" >&2
            echo "key-backup: fix the missing handles before you wipe the machine" >&2
          fi

          cat <<EOF
          key-backup: wrote $archive
          key-backup: checksum $archive.sha256
          key-backup: handles: $handles, setup script: $script_state

          Upload both files to Proton Pass:
            1. Create a Note item named "nix-config restore bundle — $host"
               in the vault that holds recovery material.
            2. Attach the .tar.gz and the .sha256, then save.
            3. Once Pass shows them, remove the local copies:
                 shred -u "$archive" "$archive.sha256"

          Proton Pass encrypts attachments end-to-end; the archive itself is not
          separately encrypted. Restoring needs the physical YubiKey plus the PIN
          for signing or a touch for sudo. The host SSH key and the admin age key
          (~/.config/sops/keys.age) have separate custody.

          Restore on a fresh machine after bootstrap:
            nix run .#key-restore -- <downloaded-bundle.tar.gz>
          EOF
        '';
      };

      key-restore = pkgs.writeShellApplication {
        name = "key-restore";
        runtimeInputs = with pkgs; [
          coreutils
          findutils
          gawk
          gnutar
          gzip
          gnused
          openssh
        ];
        text = ''
          usage() {
            cat <<'EOF'
          Usage: nix run .#key-restore -- <bundle.tar.gz> [--force] [--no-verify]

          Restores the FIDO2 credential handles from a Proton Pass backup made
          by `nix run .#key-backup`. Run it after `nix run .#bootstrap`.
          EOF
          }

          umask 077
          force=0
          verify=1
          archive=""
          pubkeys="${yubikeyPubkeys}"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --force) force=1 ;;
              --no-verify) verify=0 ;;
              --pubkeys)
                if [ "$#" -lt 2 ]; then
                  echo "key-restore: --pubkeys needs a path" >&2
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

          if tar -tvzf "$archive" | awk 'substr($0, 1, 1) ~ /[lh]/ { found=1 } END { exit !found }'; then
            echo "key-restore: the bundle contains links; refusing" >&2
            exit 1
          fi

          stage="$(mktemp -d)"
          trap 'rm -rf "$stage"' EXIT
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
            find home -type f -print0 | sort -z | xargs -0 sha256sum >.recomputed
            if ! cmp -s .recomputed SHA256SUMS; then
              echo "key-restore: SHA256SUMS does not match the archive contents" >&2
              exit 1
            fi
          )

          host="$(sed -n 's/^host: //p' "$stage/MANIFEST")"
          created="$(sed -n 's/^created: //p' "$stage/MANIFEST")"
          missing="$(sed -n 's/^missing: //p' "$stage/MANIFEST")"
          echo "key-restore: bundle from $host ($created)"
          current="$(uname -n)"
          current="''${current%%.*}"
          if [ "$host" != "$current" ]; then
            echo "key-restore: bundle was made on $host; restoring handles on $current" >&2
          fi
          if [ -n "$missing" ] && [ "$missing" != none ]; then
            echo "key-restore: the backup was missing: $missing" >&2
          fi

          expected_pubkey() {
            awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$pubkeys"
          }
          first_two() {
            awk '{ print $1" "$2 }'
          }

          # Refuse before writing anything if a handle already exists or does
          # not match the committed public half. A partial restore would leave
          # the machine in a state yk-login cannot explain.
          while IFS=$'\t' read -r key _; do
            [ -n "$key" ] || continue
            src="$stage/home/.config/ssh-sk/$key"
            [ -f "$src" ] || continue
            dest="$HOME/.config/ssh-sk/$key"
            if [ -e "$dest" ] && [ "$force" -eq 0 ]; then
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

          # Reject a handle the repo does not know about; the map is the
          # authoritative credential inventory.
          for src in "$stage"/home/.config/ssh-sk/*/*; do
            [ -f "$src" ] || continue
            key="''${src#"$stage/home/.config/ssh-sk/"}"
            if ! awk -F '\t' -v k="$key" '$1 == k { found=1 } END { exit !found }' "$pubkeys"; then
              echo "key-restore: $key is not a committed credential" >&2
              exit 1
            fi
          done

          if [ -f "$stage/home/dev/setup-yubikey.sh" ] && [ -e "$HOME/dev/setup-yubikey.sh" ] && [ "$force" -eq 0 ]; then
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

          cat <<EOF
          key-restore: installed $installed handle(s) under $HOME/.config/ssh-sk

          Next:
            home-manager switch        # if bootstrap has not already written the .pub files
            yk-login                   # loads the handles, caches the PIN
            ssh smortress true         # no prompt
            ssh -t smortress sudo true # one touch

          The host SSH key and the admin age key are not in this bundle: the host
          key comes from secrets/hosts/<host>/ via install, or is re-minted with
          nix run .#host-key and re-keyed in .sops.yaml; the admin identity stays
          on the laptops.
          EOF
        '';
      };

      # Runs the minimal Cloudflare OpenTofu config from a root-owned state
      # directory. The API token and tunnel UUID stay in sops-decrypted files;
      # account/email inputs are non-secret.
      cloudflareTofu =
        name: action:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [
            pkgs.opentofu
            pkgs.jq
            pkgs.coreutils
            pkgs.bash
          ];
          text = ''
            if [ "$(id -u)" -ne 0 ]; then
              echo "${name}: run as root (state and secrets are root-only)" >&2
              exit 1
            fi

            state="''${CLOUDFLARE_TOFU_DIR:-/var/lib/cloudflare-tofu}"
            token_file="''${CLOUDFLARE_API_TOKEN_FILE:-/run/secrets/cloudflare-api-token}"
            creds="''${CLOUDFLARE_TUNNEL_CREDENTIALS:-/run/secrets/cloudflared-credentials}"

            for f in "$token_file" "$creds"; do
              [ -r "$f" ] || { echo "${name}: cannot read $f" >&2; exit 1; }
            done

            install -d -m 0700 "$state"
            rm -f "$state"/*.tf
            cp ${../../tofu}/*.tf "$state"/
            cp ${../../tofu}/.terraform.lock.hcl "$state"/
            chmod 0600 "$state"/*.tf "$state"/.terraform.lock.hcl

            export CLOUDFLARE_API_TOKEN
            CLOUDFLARE_API_TOKEN=$(tr -d '[:space:]' < "$token_file")
            # An empty account id is not a plan-time error: OpenTofu sends it to
            # the API, which rejects account-scoped resources mid-apply after
            # others have already changed. The tunnel credentials carry the same
            # account tag, so they cover a missing or dangling /etc entry.
            account_id="''${CLOUDFLARE_ACCOUNT_ID:-}"
            if [ -z "$account_id" ] && [ -r /etc/cloudflare-tofu/account-id ]; then
              account_id=$(cat /etc/cloudflare-tofu/account-id)
            fi
            if [ -z "$account_id" ]; then
              account_id=$(jq -er '.AccountTag' "$creds")
            fi
            [ -n "$account_id" ] || {
              echo "${name}: no Cloudflare account id; set CLOUDFLARE_ACCOUNT_ID" >&2
              exit 1
            }
            export TF_VAR_account_id="$account_id"
            export TF_VAR_domain="''${CLOUDFLARE_DOMAIN:-sammohr.dev}"
            export TF_VAR_email="''${CLOUDFLARE_ALERT_EMAIL:-sam@sammohr.dev}"
            export TF_VAR_tunnel_id
            TF_VAR_tunnel_id=$(jq -er '.TunnelID' "$creds")

            cd "$state"
            # Always init: a provider/lockfile change needs `init` to pick up
            # the new lock, and a warm .terraform makes it a cheap no-op.
            tofu init -input=false
            exec tofu ${action} "$@"
          '';
        };

      cloudflarePlan = cloudflareTofu "cloudflare-plan" "plan";
      cloudflareApply = cloudflareTofu "cloudflare-apply" "apply";
      cloudflareCommand = cloudflareTofu "cloudflare-tofu" "";

      # One interactive Proton login, written straight into the mount's state
      # dir. protondrive has no `config reconnect`, and rclone cannot use a
      # security-key 2FA factor, so this asks for the password (obscured through
      # stdin, never argv) and a TOTP code, then proves the login by listing the
      # remote before swapping the config in under a stopped mount.
      protonAuth = pkgs.writeShellApplication {
        name = "proton-auth";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.rclone
          pkgs.systemd
          pkgs.util-linux
        ];
        text = ''
          if [ "$(id -u)" -ne 0 ]; then
            echo "proton-auth: run as root (the mount and its token are proton-owned)" >&2
            exit 1
          fi

          state=/var/lib/proton
          config=$state/rclone.conf
          pending=$state/rclone.conf.pending
          unit=proton-mount.service

          if ! systemctl cat "$unit" >/dev/null 2>&1; then
            echo "proton-auth: $unit is not installed; enable protonDrive on this host first" >&2
            exit 1
          fi

          install -d -o proton -g proton -m 0700 "$state"
          rm -f "$pending"

          if [ -s "$config" ]; then
            echo "proton-auth: replacing the stored credentials. protondrive has no"
            echo "proton-auth: reconnect, so this logs in again; revoke the previous"
            echo "proton-auth: session in Proton afterwards."
          fi

          read -r -p "Proton username (email): " username
          read -r -s -p "Proton password: " password
          echo
          read -r -s -p "Mailbox password (blank for a one-password account): " mailbox
          echo
          read -r -p "2FA code (6 digits; blank if TOTP is disabled): " code

          obscure() { printf '%s' "$1" | rclone obscure -; }

          umask 077
          {
            printf '[proton]\n'
            printf 'type = protondrive\n'
            printf 'username = %s\n' "$username"
            printf 'password = %s\n' "$(obscure "$password")"
            if [ -n "$mailbox" ]; then
              printf 'mailbox_password = %s\n' "$(obscure "$mailbox")"
            fi
            printf 'enable_caching = false\n'
          } >"$pending"
          chown proton:proton "$pending"
          chmod 600 "$pending"

          echo "proton-auth: logging in and storing the refresh token..."
          login_args=()
          [ -n "$code" ] && login_args+=(--protondrive-2fa "$code")
          login_log=$(mktemp)
          if ! runuser -u proton -- env HOME="$state" \
            rclone --config "$pending" lsd proton: "''${login_args[@]}" \
            >"$login_log" 2>&1; then
            echo "proton-auth: login failed; rclone said:" >&2
            tail -n 6 "$login_log" >&2
            rm -f "$pending" "$login_log"
            echo "proton-auth: common causes: wrong login or mailbox password; a wrong" >&2
            echo "proton-auth: or expired TOTP code; TOTP not enabled (rclone cannot use" >&2
            echo "proton-auth: a security key); or HTTP 429 rate limiting, which needs a" >&2
            echo "proton-auth: wait before retrying." >&2
            exit 1
          fi
          rm -f "$login_log"
          unset password mailbox code

          if ! grep -q '^client_refresh_token' "$pending"; then
            rm -f "$pending"
            echo "proton-auth: login succeeded but no refresh token was written" >&2
            exit 1
          fi

          # Swap under a stopped mount: rclone rewrites this file in place when it
          # refreshes, so replacing it while running would drop the new token.
          systemctl stop "$unit" 2>/dev/null || true
          systemctl reset-failed "$unit" 2>/dev/null || true
          mv -f "$pending" "$config"
          chown proton:proton "$config"
          chmod 600 "$config"
          systemctl start "$unit"

          if ! mountpoint -q /srv/proton; then
            echo "proton-auth: $unit did not bring the mount up:" >&2
            systemctl status --no-pager -l "$unit" >&2 || true
            exit 1
          fi
          echo "proton-auth: credentials written to $config; /srv/proton is mounted"
        '';
      };
    in
    {
      packages.bootstrap = bootstrap;
      packages.install = install;
      packages.host-key = host-key;
      # `nix run .#key-backup` — archive the FIDO2 handles for Proton Pass.
      packages.key-backup = key-backup;
      # `nix run .#key-restore -- <bundle>` — restore them on a fresh machine.
      packages.key-restore = key-restore;
      # `nix run github:smores56/nix-config#bootstrap` — the fresh-machine entry
      # point.
      apps.bootstrap = {
        type = "app";
        program = "${bootstrap}/bin/bootstrap";
      };
      # `nix run .#install -- <host> <target-host>` — blank-machine install.
      apps.install = {
        type = "app";
        program = "${install}/bin/install";
      };
      # `nix run .#host-key -- <host>` — generate a host key + print its age
      # recipient.
      apps.host-key = {
        type = "app";
        program = "${host-key}/bin/host-key";
      };
      # `nix run .#key-backup` / `..#key-restore -- <bundle>` — move the FIDO2
      # handles between a machine and Proton Pass.
      apps.key-backup = {
        type = "app";
        program = "${key-backup}/bin/key-backup";
      };
      apps.key-restore = {
        type = "app";
        program = "${key-restore}/bin/key-restore";
      };
      # `sudo nix run .#cloudflare-plan` / `..#cloudflare-apply`.
      apps.cloudflare-plan = {
        type = "app";
        program = "${cloudflarePlan}/bin/cloudflare-plan";
      };
      apps.cloudflare-apply = {
        type = "app";
        program = "${cloudflareApply}/bin/cloudflare-apply";
      };
      # `sudo nix run .#cloudflare-tofu -- import <address> <id>` / `state list`.
      apps.cloudflare-tofu = {
        type = "app";
        program = "${cloudflareCommand}/bin/cloudflare-tofu";
      };
      # `sudo nix run .#proton-auth` — the one interactive Proton login a new
      # machine needs (also called by `bootstrap` when the mount is installed
      # and its config is missing).
      apps.proton-auth = {
        type = "app";
        program = "${protonAuth}/bin/proton-auth";
      };
      packages.proton-auth = protonAuth;
    };
}
