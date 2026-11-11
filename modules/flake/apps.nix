{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };

      # The script is idempotent and clones the repo to $HOME/repos itself.
      bootstrap = pkgs.writeShellApplication {
        name = "bootstrap";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          findutils
          git
          openssh
          gh
        ];
        text = ''
          exec ${inputs.self}/bootstrap.sh "$@"
        '';
      };

      # Writes the generated hardware config back into the checkout; needs modules/hosts/<host>/{default.nix,disko.nix}.
      install = pkgs.writeShellApplication {
        name = "install";
        runtimeInputs = [
          pkgs.gawk
          pkgs.git
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

          The host must already have modules/hosts/<host>/{default.nix,disko.nix}
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
          for f in default.nix disko.nix; do
            if [ ! -f "$host_dir/$f" ]; then
              echo "error: $host_dir/$f is missing — create modules/hosts/$host/ first (see AGENTS.md)" >&2
              exit 1
            fi
            git ls-files --error-unmatch "$host_dir/$f" >/dev/null 2>&1 \
              || { echo "error: $host_dir/$f is not tracked by git — commit it (flakes only see tracked files)" >&2; exit 1; }
          done
          # Host-local modules are read by the flake too; untracked ones pass the checks above and fail late in the eval.
          untracked="$(git ls-files --others --exclude-standard "$host_dir")"
          if [ -n "$untracked" ]; then
            echo "error: $host_dir has untracked files — commit them (flakes only see tracked files):" >&2
            printf '%s\n' "$untracked" >&2
            exit 1
          fi

          hardware="$host_dir/hardware.nix"

          # The pre-generated host key (gitignored) is delivered before first boot so sops-nix can decrypt;
          # it must be the identity .sops.yaml binds to &<host> or the machine cannot boot.
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
            # A recipient can appear in .sops.yaml without being bound to a rule, and a regenerated key
            # encrypts to a recipient the host cannot use: prove the key decrypts.
            preflight=""
            if [ -f "secrets/$host.yaml" ]; then
              preflight="secrets/$host.yaml"
            elif [ -f secrets/common.yaml ]; then
              preflight="secrets/common.yaml"
            fi
            if [ -n "$preflight" ]; then
              # sops runs the admin-key command eagerly; an empty value makes it execute "" and crash, so unset it.
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

      # `install` delivers it via --extra-files; prints its sops age recipient.
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

      # PIV private keys are generated on the token and cannot be exported, so they are not backed up.
      yubikeyKeys = import ../lib/yubikey-keys.nix;
      yubikeyPubkeys = pkgs.writeText "yubikey-pubkeys" (
        pkgs.lib.concatMapStrings (k: "${k.key}\t${k.pubkey}\n") yubikeyKeys.sudo
      );

      keyScript =
        file:
        builtins.replaceStrings [ "@PUBKEYS@" ] [ "${yubikeyPubkeys}" ] (
          builtins.readFile ./apps/key-common.sh + builtins.readFile file
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
        text = keyScript ./apps/key-backup.sh;
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
        text = keyScript ./apps/key-restore.sh;
      };

      # Runs from a root-owned state directory; the API token and tunnel UUID stay in sops-decrypted files.
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
            # An empty account id is not a plan-time error: the API rejects account-scoped resources mid-apply
            # after others changed. The tunnel credentials carry the same account tag, so they cover it.
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
            # Always init: a lockfile change needs it, and a warm .terraform makes it a no-op.
            tofu init -input=false
            exec tofu ${action} "$@"
          '';
        };

      # The read-only Tuta calendar core (#589), buildable on any host: the SDK
      # feature is a documented `passthru.sdk` build that needs TutaBridge's
      # prepared SDK (pkgs/tuta-ics/default.nix).
      tuta-ics = pkgs.callPackage ../../pkgs/tuta-ics { };

      cloudflarePlan = cloudflareTofu "cloudflare-plan" "plan";
      cloudflareApply = cloudflareTofu "cloudflare-apply" "apply";
      cloudflareCommand = cloudflareTofu "cloudflare-tofu" "";

    in
    {
      packages.tuta-ics = tuta-ics;
      # Documented broken build: the SDK is not vendored (pkgs/tuta-ics/default.nix).
      packages.tuta-ics-sdk = tuta-ics.passthru.sdk;
      packages.bootstrap = bootstrap;
      packages.install = install;
      packages.host-key = host-key;
      packages.key-backup = key-backup;
      packages.key-restore = key-restore;
      apps.bootstrap = {
        type = "app";
        program = "${bootstrap}/bin/bootstrap";
      };
      apps.install = {
        type = "app";
        program = "${install}/bin/install";
      };
      apps.host-key = {
        type = "app";
        program = "${host-key}/bin/host-key";
      };
      apps.key-backup = {
        type = "app";
        program = "${key-backup}/bin/key-backup";
      };
      apps.key-restore = {
        type = "app";
        program = "${key-restore}/bin/key-restore";
      };
      apps.cloudflare-plan = {
        type = "app";
        program = "${cloudflarePlan}/bin/cloudflare-plan";
      };
      apps.cloudflare-apply = {
        type = "app";
        program = "${cloudflareApply}/bin/cloudflare-apply";
      };
      apps.cloudflare-tofu = {
        type = "app";
        program = "${cloudflareCommand}/bin/cloudflare-tofu";
      };
    };
}
