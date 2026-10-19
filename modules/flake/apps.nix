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
                if SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$key_priv")" \
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
            export TF_VAR_account_id="''${CLOUDFLARE_ACCOUNT_ID:-$(cat /etc/cloudflare-tofu/account-id)}"
            export TF_VAR_domain="''${CLOUDFLARE_DOMAIN:-sammohr.dev}"
            export TF_VAR_email="''${CLOUDFLARE_ALERT_EMAIL:-sam@sammohr.dev}"
            export TF_VAR_tunnel_id
            TF_VAR_tunnel_id=$(jq -er '.TunnelID' "$creds")

            cd "$state"
            if [ ! -d .terraform ]; then
              tofu init -input=false
            fi
            exec tofu ${action} "$@"
          '';
        };

      cloudflarePlan = cloudflareTofu "cloudflare-plan" "plan";
      cloudflareApply = cloudflareTofu "cloudflare-apply" "apply";
      cloudflareCommand = cloudflareTofu "cloudflare-tofu" "";
    in
    {
      packages.bootstrap = bootstrap;
      packages.install = install;
      packages.host-key = host-key;
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
    };
}
