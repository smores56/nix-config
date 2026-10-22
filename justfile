# Command index for this repo. `just --list` is the source of truth.
# Nix remains the implementation; these recipes only assemble the commands.

# Show this command index.
default:
    @just --list

# Check that the flake evaluates on every system (does not build).
check:
    nix flake check --all-systems --no-build

# Build every check for the current system.
check-build:
    nix flake check

# Run the Python unit suite.
test:
    nix run nixpkgs#python3 -- -m unittest discover -s tests

# Format the tree.
fmt:
    nix fmt

# Apply the NixOS configuration for a host.
switch host:
    sudo nixos-rebuild switch --flake .#{{host}}

# Apply the NixOS configuration on next boot.
boot host:
    sudo nixos-rebuild boot --flake .#{{host}}

# Apply a home-manager configuration (e.g. smores smortress).
home-switch user host:
    home-manager switch --flake .#{{user}}@{{host}} --no-write-lock-file

# Install NixOS on a blank machine (wipes its disks).
install host target:
    nix run .#install -- {{host}} {{target}}

# Generate a host key and print its age recipient.
host-key host:
    nix run .#host-key -- {{host}}

# Bootstrap a fresh machine.
bootstrap:
    nix run .#bootstrap

# Plan the Cloudflare edge configuration as root.
cloudflare-plan:
    sudo nix run .#cloudflare-plan

# Apply the Cloudflare edge configuration as root.
cloudflare-apply:
    sudo nix run .#cloudflare-apply

# Run raw tofu in the root-only state directory.
cloudflare-tofu *args:
    sudo nix run .#cloudflare-tofu -- {{args}}

# Ingest sdlc issues, personal notes, repo docs, and a Maki session sample into memory (on smortress).
memory-ingest *args:
    memory ingest all {{args}}

# Snapshot the memory registry and the graph now (the nightly unit does this).
memory-export:
    sudo systemctl start memory-export.service
    journalctl -u memory-export.service -n 20 --no-pager

# Verify and restore one memory export (stops the memory services on smortress).
memory-restore dir:
    sudo memory restore {{dir}}

# Stop memory, wipe the derived graph and the registry, then start it again.
# FalkorDB must stop before its directory is wiped: a running instance rewrites
# its AOF and would recreate what this deletes.
memory-rebuild:
    sudo systemctl stop memory-mcp memory-graphiti-mcp memory-llm-proxy memory-falkordb
    sudo find /var/lib/memory/falkordb -mindepth 1 -delete
    sudo rm -f /var/lib/memory/registry.sqlite* /var/lib/memory/index.sqlite* /var/lib/memory/audit.jsonl /var/lib/memory/internal.token /var/lib/memory/.restore-in-progress
    sudo systemctl start memory-falkordb memory-llm-proxy memory-graphiti-mcp memory-mcp

# Show backup timers and failed backup units.
backup-status:
    systemctl list-timers 'backup-*'
    systemctl --failed 'backup-*'

# Start one backup run (dataset name, lowercase).
backup-run name:
    sudo systemctl start backup-{{name}}.service

# Follow a backup unit's journal.
backup-logs name:
    journalctl -u backup-{{name}}.service -f

# Prove the local and offsite mirrors against the live source.
restore-drill dataset:
    sudo bash modules/features/backup/drills/restore-drill.sh {{dataset}}

# Update every flake input.
update:
    nix flake update
