# Show this command index.
default:
    @just --list

# Check that the flake evaluates on every system (does not build).
check:
    nix flake check --all-systems --no-build

# Build every check for the current system.
check-build:
    nix flake check

# Assert the Linux agent VM boundary from inside the guest.
agent-vm-check:
    agent-vm-check

# Assert the agent VM view, shares, secrets and firewall from the host.
agent-vm-verify:
    sudo agent-vm-verify

# Run the Python unit suite with its dependencies.
test:
    nix build --no-link .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).unit-tests

# Evaluate one home-manager configuration (e.g. smores smortress).
verify-home user host:
    nix eval --raw .#homeConfigurations.'"{{user}}@{{host}}"'.activationPackage.drvPath

# Evaluate one NixOS configuration.
verify-nixos host:
    nix eval --raw .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath

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

# Install the work Mac's brew casks from its Brewfile (adds only; never uninstalls).
# Built from the flake, so it works before the first home-manager switch.
brew-bundle:
    brew bundle --file="$(nix build --no-link --print-out-paths '.#homeConfigurations."sam@smoreswork".config.xdg.configFile."homebrew/Brewfile".source')"

# Install NixOS on a blank machine (wipes its disks).
install host target:
    nix run .#install -- {{host}} {{target}}

# Generate a host key and print its age recipient.
host-key host:
    nix run .#host-key -- {{host}}

# Archive the FIDO2 handles to Bitwarden before wiping a machine.
key-backup *args:
    nix run .#key-backup -- {{args}}

# Restore the FIDO2 handles from a Bitwarden bundle.
key-restore bundle *args:
    nix run .#key-restore -- "{{bundle}}" {{args}}

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

# Show memory queue counts per status and group, plus recent extractions.
memory-status:
    sg memory -c 'memory status'
    sg memory -c 'cp /var/lib/memory/registry.sqlite /tmp/memory-status.sqlite'
    nix shell nixpkgs#sqlite -c sqlite3 /tmp/memory-status.sqlite "select status, count(*) from episodes group by status;" "select group_id, sum(status = 'pending') as pending, sum(status = 'active') as active from episodes group by group_id order by pending desc;"
    -journalctl -u memory-graphiti-mcp --since '10 min ago' --no-pager | grep -c 'Successfully processed'

# Snapshot the memory registry and the graph now (the nightly unit does this).
memory-export:
    sudo systemctl start memory-export.service
    journalctl -u memory-export.service -n 20 --no-pager

# Verify and restore one memory export (stops the memory services on smortress).
memory-restore dir:
    sudo memory restore {{dir}}

# Requeue active rows the graph no longer holds; repeat until none are left.
memory-reindex *args:
    sg memory -c 'memory reindex {{args}}'

# Wipe the derived graph (the registry stays), then restart memory; follow with `just memory-reindex --all` until it reports nothing left.
memory-rebuild:
    sudo systemctl stop memory-mcp memory-graphiti-mcp memory-llm-proxy memory-falkordb
    sudo find /var/lib/memory/falkordb -mindepth 1 -delete
    sudo systemctl start memory-falkordb memory-llm-proxy memory-graphiti-mcp memory-mcp

# Show the restic timers and any failed backup units.
backup-status:
    systemctl list-timers 'restic-*'
    systemctl --failed 'restic-*'

# Start one restic run (repo name: r2 or local).
backup-run repo:
    sudo systemctl start restic-backups-{{repo}}.service

# Follow a restic unit's journal.
backup-logs repo:
    journalctl -u restic-backups-{{repo}}.service -f

# Update every flake input.
update:
    nix flake update

# Show the agent guest's booted/current/expected closures and human sessions.
agent-vm-status:
    agent-sandbox status

# Apply a live userland update, or the boot a guest closure change needs.
agent-vm-update:
    sudo agent-vm-update
