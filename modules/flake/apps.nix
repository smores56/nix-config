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
        runtimeInputs = [ pkgs.nixos-anywhere ];
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
          done

          hardware="$host_dir/hardware.nix"

          # A pre-generated host key (secrets/hosts/<host>/, gitignored) is
          # delivered before first boot so sops-nix can decrypt that host's
          # secrets. Generate it with `nix run .#host-key -- <host>`.
          extra_files=()
          if [ -d "secrets/hosts/$host" ]; then
            echo "Delivering secrets/hosts/$host into the new root"
            extra_files=(--extra-files "secrets/hosts/$host")
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
    };
}
