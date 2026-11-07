# The vault: one plaintext tree, owned by the `vault` user and synced as plaintext between the
# hosts that hold it. Nothing reads it directly; `sudo vault` mounts it for one foreground session.
#
# Syncthing runs as `vault` (a system service, not the human's user unit), so the daemon can only
# write its own tree and the human's uid has no access at rest. Device IDs live in
# `modules/syncthing-devices.nix`; the folder keeps the id `vault`, is shared with every device in
# that table, and versions land outside both the synced tree and restic's source path.
#
# Activate this only together with the migration. The rule below moves the tree to the `vault` user,
# and the one-time Cryptomator conversion needs the human's own access to the ciphertext first. A
# premature activation stops sync rather than losing data (the daemon cannot write a tree it does not
# own), but it also blocks the conversion until ownership is put back by hand.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  devices = import ../syncthing-devices.nix;

  # Pinned so ownership and the bindfs mapping stay stable across rebuilds. 1000 is the human,
  # 982 is the memory service.
  id = 981;

  store = "/var/lib/data/vault";
  # Written by the one-time migration (docs/manual-steps.md) once the tree is plaintext and
  # owned by `vault`; until then the daemon does not start.
  migrated = "/var/lib/vault-migrated";
  stateDir = "/var/lib/syncthing";
  versions = "/var/lib/syncthing-versions/vault";
  oldState = "/home/${config.machine.username}/.local/state/syncthing";
  home = "/home/${config.machine.username}";
in
{
  options.vaultSync.device = lib.mkOption {
    type = lib.types.str;
    description = "This host's key in `modules/syncthing-devices.nix`; the folder is shared with every other device in that table.";
  };

  config = {
    assertions = [
      {
        assertion = builtins.hasAttr config.vaultSync.device devices;
        message = "vaultSync.device (${config.vaultSync.device}) needs its ID in modules/syncthing-devices.nix before Syncthing can run here; the local device is part of the config Syncthing writes.";
      }
    ];

    users.groups.vault.gid = id;
    users.users.vault = {
      isSystemUser = true;
      uid = id;
      group = "vault";
      home = stateDir;
      createHome = true;
      homeMode = "0700";
    };

    systemd.tmpfiles.rules = [
      "d ${store} 0700 vault vault -"
      "d ${stateDir} 0700 vault vault -"
      "d /var/lib/syncthing-versions 0700 vault vault -"
      "d ${versions} 0700 vault vault -"
    ];

    # The device ID is the hash of cert.pem and those IDs are committed, so the move from the
    # human's home to the vault user's state dir carries the two key files over once. The guard
    # means a later rebuild never overwrites a live identity.
    system.activationScripts.vaultSyncthingIdentity = {
      deps = [ "users" ];
      text = ''
        if [ ! -e ${stateDir}/cert.pem ] && [ ! -e ${stateDir}/key.pem ] \
          && [ -e ${oldState}/cert.pem ] && [ -e ${oldState}/key.pem ]; then
          install -o vault -g vault -m 0600 ${oldState}/cert.pem ${stateDir}/cert.pem
          install -o vault -g vault -m 0600 ${oldState}/key.pem ${stateDir}/key.pem
        fi
      '';
    };

    services.syncthing = {
      enable = true;
      user = "vault";
      group = "vault";
      dataDir = stateDir;
      # The module would otherwise keep config and index under ${stateDir}/.config/syncthing,
      # where the identity copy never lands and Syncthing would mint a fresh device ID.
      configDir = stateDir;
      databaseDir = stateDir;
      # Declarative only: UI changes do not survive the next activation.
      overrideDevices = true;
      overrideFolders = true;
      settings = {
        # Relays stay on: laptops are not always on the server's network.
        options.relaysEnabled = true;
        devices = lib.mapAttrs (name: value: {
          id = value;
          name = name;
        }) devices;
        folders.vault = {
          id = "vault";
          label = "Vault";
          path = store;
          type = "sendreceive";
          devices = lib.remove config.vaultSync.device (lib.attrNames devices);
          # Hourly full scan still runs because some changes bypass inotify.
          fsWatcherEnabled = true;
          rescanIntervalS = 3600;
          # Permissions differ between the hosts' filesystems; syncing them would churn every scan.
          ignorePerms = true;
          versioning = {
            type = "staggered";
            params = {
              maxAge = "2592000";
              cleanupIntervalS = "3600";
            };
            fsPath = versions;
          };
        };
      };
    };

    # A bindfs mount outlives a killed `sudo vault`; close it at boot so no stale mount survives the
    # session that opened it. The condition keeps the unit a no-op when nothing is mounted.
    systemd.services.vault-unmount = {
      description = "Close a stale vault mount";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathIsMountPoint = "${home}/Vault";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.util-linux}/bin/umount -R ${home}/Vault";
      };
    };

    # tmpfiles fixes the top-level directory only, so nothing starts syncing until the
    # migration has chowned the whole tree to `vault` and dropped this marker.
    systemd.services.syncthing.unitConfig.ConditionPathExists = migrated;
    systemd.services.syncthing.unitConfig.RequiresMountsFor = [ stateDir ];
  };
}
