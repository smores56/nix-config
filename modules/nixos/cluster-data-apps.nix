# Cutover switch for smores56/sdlc#580: once the `cluster` guest serves Immich,
# Navidrome, Calibre and Graphiti, the host must stop running its own copies and
# stop dumping Immich's database into the tree restic walks.
#
# The native modules stay in the tree on purpose (`immich.nix`, `navidrome.nix`,
# `memory.nix`, and calibre's home-manager service). Their deletion is the
# live-gated second half of the ticket: it needs a week of the cluster serving
# first, and it must be one commit that removes the module from the server
# profile *and* deletes the file. Until then this module neutralises their
# runtime contributions, which is why every unit, container and service is
# forced off here rather than left to `disabledModules` — `disabledModules` is
# read while the module list is collected, before any option has a value, so it
# cannot be conditional.
#
# Wiring (smortress, after every app has served from the cluster):
#   1. list this file in modules/hosts/smortress/default.nix `nixosModules`;
#   2. set `clusterDataApps.enable = true;` in that host's `nixosOptions`.
# Step 2 alone is the cutover; step 1 is inert while the option keeps its default.
#
# Not handled here, because they live on another plane or in a file that must
# keep working until it is deleted:
#   - `services.calibre` is a home-manager user service (modules/features/calibre.nix);
#     stop it with `systemctl --user stop calibre-server` or drop it from the
#     server profile's home list at the same time as this switch.
#   - The `memory` user and group, its tmpfiles directories (including
#     /var/lib/data/memory-export), the `extraGroups` entry and the wrapper
#     package stay defined by `memory.nix` until that file is deleted.
#   - The host's `memory.sammohr.dev` route keeps pointing at the host wrapper
#     until the wrapper itself moves; disabling these units without repointing
#     the tunnel would take maki's memory offline.
{
  config,
  lib,
  ...
}:
let
  cfg = config.clusterDataApps;

  # Every unit modules/nixos/memory.nix defines. Disabling the unit removes it
  # from the generation; the podman containers are emptied separately below.
  memoryUnits = [
    "memory-falkordb"
    "memory-graphiti-mcp"
    "memory-llm-proxy"
    "memory-mcp"
    "memory-export"
  ];

  # The host's Immich dump, replaced by the platform CronJob that writes
  # /var/lib/data/immich/db-dumps/immich.dump at 02:45 (see the platform
  # repo's docs/data-migration.md). Both restic units only `want` it, so
  # removing the unit does not fail a backup run.
  retiredUnits = memoryUnits ++ [ "restic-db-dump" ];
in
{
  options.clusterDataApps.enable = lib.mkEnableOption ''
    serving the data apps from the `cluster` guest instead of this host. Turning
    it on disables the native Immich, Navidrome and memory services, the host's
    Immich dump unit and the rootless podman containers `modules/nixos/memory.nix`
    defines. It does not delete their modules or data; that is the live-gated
    follow-up (smores56/sdlc#580)
  '';

  config = lib.mkIf cfg.enable {
    # Both modules set `enable = true` unconditionally; the cluster owns them now.
    services.immich.enable = lib.mkForce false;
    services.navidrome.enable = lib.mkForce false;

    # memory.nix defines its containers without an enable option.
    virtualisation.oci-containers.containers = lib.mkForce { };

    systemd.services = lib.genAttrs retiredUnits (_: {
      enable = lib.mkForce false;
    });
    # Unconditional on purpose: this module only belongs on a host that composes
    # modules/nixos/memory.nix, which is what defines the timer. Guarding on
    # `config.systemd.timers` from inside a definition of it recurses.
    systemd.timers.memory-export.enable = lib.mkForce false;

    assertions = [
      {
        # Guarded with hasAttr so the module also evaluates on a host that does
        # not compose the native app modules at all.
        assertion =
          (builtins.hasAttr "immich" config.services -> !config.services.immich.enable)
          && (builtins.hasAttr "navidrome" config.services -> !config.services.navidrome.enable);
        message = "cluster-data-apps: Immich and Navidrome must stay off while the cluster serves them";
      }
      {
        assertion =
          !(builtins.hasAttr "oci-containers" config.virtualisation)
          || config.virtualisation.oci-containers.containers == { };
        message = "cluster-data-apps: no rootless podman container may remain; memory.nix must not add one";
      }
      {
        assertion = lib.all (
          name: !(builtins.hasAttr name config.systemd.services) || !config.systemd.services.${name}.enable
        ) retiredUnits;
        message = "cluster-data-apps: the host's memory units and Immich dump must be disabled";
      }
      {
        assertion = config ? microvm && config.microvm.vms ? cluster;
        message = "cluster-data-apps: the `cluster` guest (modules/nixos/cluster-vm.nix) must be configured; there is nothing to cut over to";
      }
    ];
  };
}
