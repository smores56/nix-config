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
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.nixos-anywhere
          pkgs.openssh
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
          # Host-local modules (`nixos = [ ./boot.nix ]`) are read by the flake
          # too; untracked ones pass the checks above and fail late in the eval.
          untracked="$(git ls-files --others --exclude-standard "$host_dir")"
          if [ -n "$untracked" ]; then
            echo "error: $host_dir has untracked files — commit them (flakes only see tracked files):" >&2
            printf '%s\n' "$untracked" >&2
            exit 1
          fi

          hardware="$host_dir/hardware.nix"

          # A pre-generated host key (secrets/hosts/<host>/, gitignored) is
          # delivered before first boot so sops-nix can decrypt that host's
          # secrets. It must be the identity .sops.yaml binds to &<host>:
          # delivering anything else installs a machine that cannot boot.
          extra_files=()
          key_dir="secrets/hosts/$host"
          if [ -d "$key_dir" ]; then
            echo "Delivering $key_dir into the new root"
            extra_files=(--extra-files "$key_dir")
            key_priv="$key_dir/etc/ssh/ssh_host_ed25519_key"
            if [ ! -f "$key_priv" ]; then
              echo "error: $key_dir exists but has no etc/ssh/ssh_host_ed25519_key" >&2
              exit 1
            fi
            tmp_pub="$(mktemp)"
            trap 'rm -f "$tmp_pub"' EXIT
            if ! ssh-keygen -y -P "" -f "$key_priv" >"$tmp_pub"; then
              echo "error: $key_priv is unreadable or passphrase-protected" >&2
              exit 1
            fi
            recipient="$(ssh-to-age -i "$tmp_pub")"
            anchor="$(awk -v h="&$host" '$1 == "-" && $2 == h { print $3; exit }' .sops.yaml)"
            if [ -z "$anchor" ]; then
              echo "error: .sops.yaml has no '&$host <age1...>' anchor for the delivered host key" >&2
              exit 1
            fi
            if [ "$anchor" != "$recipient" ]; then
              echo "error: delivered host key derives ''${recipient}, but .sops.yaml has $anchor for &$host" >&2
              echo "error: restore the matching key with 'nix run .#key-restore -- <bundle> --host-key' before installing" >&2
              exit 1
            fi
            echo "Host key recipient ''${recipient} matches &$host in .sops.yaml"
            # Prove the delivered key actually decrypts this host's secrets. A
            # recipient can appear in .sops.yaml without being bound to a rule,
            # and a regenerated key encrypts to a recipient the host cannot use.
            preflight=""
            if [ -f "secrets/$host.yaml" ]; then
              preflight="secrets/$host.yaml"
            elif [ -f secrets/common.yaml ]; then
              preflight="secrets/common.yaml"
            fi
            if [ -n "$preflight" ]; then
              # Drop the admin-key command: sops runs it eagerly even though this
              # preflight supplies the host key; an empty value makes it try to
              # execute "" and crash, so unset it instead.
              if env -u SOPS_AGE_KEY_CMD \
                SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$key_priv")" \
                sops --decrypt "$preflight" >/dev/null 2>&1; then
                echo "Host key decrypts $preflight"
              else
                echo "error: the delivered host key cannot decrypt $preflight — fix .sops.yaml and run 'sops updatekeys $preflight' before installing" >&2
                exit 1
              fi
            fi
          elif [ "''${INSTALL_ALLOW_MISSING_HOST_KEY:-0}" = 1 ]; then
            echo "warning: installing without a host key; sops secrets will not decrypt on first boot" >&2
          else
            echo "error: $key_dir is missing, so no host key would be delivered" >&2
            echo "error: on a reinstall restore it first: nix run .#key-restore -- <bundle> --host-key" >&2
            echo "error: only a brand-new host mints one: nix run .#host-key -- $host, then sops updatekeys" >&2
            echo "error: set INSTALL_ALLOW_MISSING_HOST_KEY=1 to install anyway" >&2
            exit 1
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
          ssh-to-age
        ];
        text = ''
          umask 077

          pubkeys="${yubikeyPubkeys}"
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
                if [ "''${KEY_BUNDLE_TEST:-0}" != 1 ]; then
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
          host="''${host%%.*}"

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
          state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/key-backup"
          install -d -m 700 "$state_dir"

          stage="$(mktemp -d)"
          trap 'rm -rf "$stage"' EXIT
          mkdir -p "$stage/home"

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

          for src in "$HOME"/.config/ssh-sk/*/sudo "$HOME"/.config/ssh-sk/*/signing; do
            [ -f "$src" ] || continue
            key="''${src#"$HOME/.config/ssh-sk/"}"
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
              rm -rf "''${stage:?}/etc"
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
            echo "key-backup: run this on a laptop where the keys are enrolled and yk-login works" >&2
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
            if [ "''${#missing[@]}" -gt 0 ]; then
              printf 'missing: %s\n' "''${missing[*]}"
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

          archive="$state_dir/''${host}-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
          tar -C "$stage" -czf "$archive" .
          tar -tzf "$archive" >/dev/null
          chmod 600 "$archive"
          sha256sum "$archive" | awk '{ print $1 }' >"$archive.sha256"
          chmod 600 "$archive.sha256"

          if [ "''${#missing[@]}" -gt 0 ]; then
            echo "key-backup: WARNING: incomplete backup; missing: ''${missing[*]}" >&2
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

          Upload both files to Proton Pass:
            1. Create a Note item named "nix-config restore bundle — $host"
               in the vault that holds recovery material.
            2. Attach the .tar.gz and the .sha256, then save.
            3. Once Pass shows them, remove the local copies:
                 $remove "$archive" "$archive.sha256"

          Proton Pass encrypts attachments end-to-end; the archive itself is not
          separately encrypted. Restoring needs the physical YubiKey plus the PIN
          for signing or a touch for sudo.
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
          ssh-to-age
        ];
        text = ''
          usage() {
            cat <<'EOF'
          Usage: nix run .#key-restore -- <bundle.tar.gz> [--force] [--no-verify]
                 nix run .#key-restore -- <bundle.tar.gz> --host-key [--force]

          Restores the FIDO2 credential handles from a Proton Pass backup made
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
          pubkeys="${yubikeyPubkeys}"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --force) force=1 ;;
              --no-verify) verify=0 ;;
              --host-key) host_key_mode=1 ;;
              # Test hooks: default to the checkout locations.
              --target-dir)
                if [ "''${KEY_BUNDLE_TEST:-0}" != 1 ]; then
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
                if [ "''${KEY_BUNDLE_TEST:-0}" != 1 ]; then
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
              # Test hook: the build embeds the committed map.
              --pubkeys)
                if [ "''${KEY_BUNDLE_TEST:-0}" != 1 ]; then
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
            first_two_pub() {
              awk '{ print $1" "$2 }'
            }
            if [ -f "$src_dir/ssh_host_ed25519_key.pub" ]; then
              if [ "$(first_two_pub <"$src_dir/ssh_host_ed25519_key.pub")" != "$(printf '%s\n' "$private_pub" | first_two_pub)" ]; then
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
            dest="''${target_dir:-secrets/hosts/$host/etc/ssh}"
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
            launchctl kickstart -k gui/$(id -u)/org.nix-community.home.smortress-sudo-agent
            ssh smortress true
            ssh -t smortress sudo true

          The admin age key stays on the laptops.
          EOF
          else
            cat <<EOF
          key-restore: installed $installed handle(s) under $HOME/.config/ssh-sk

          Next:
            home-manager switch        # if bootstrap has not already written the .pub files
            yk-login                   # loads the handles, caches the PIN
            ssh smortress true         # no prompt
            ssh -t smortress sudo true # one touch

          The admin age key stays on the laptops.
          EOF
          fi

          if [ "$(sed -n 's/^host-key: //p' "$stage/MANIFEST")" = yes ]; then
            echo "The host SSH key is in this bundle; restore it with --host-key before install."
          else
            echo "This bundle carries no host key, so it cannot restore the host's sops identity."
          fi
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
