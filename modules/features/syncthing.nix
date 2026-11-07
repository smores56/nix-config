# Syncthing carries the Cryptomator vault between devices as ciphertext; the server only relays
# bytes. Device IDs live in `modules/syncthing-devices.nix`.
# Unlock the vault on one device at a time: a concurrent edit is a whole-file conflict, and two
# devices creating the same directory yield two `dir.c9r` values whose loser becomes an orphaned
# directory only Cryptomator's health check recovers.
{ config, lib, ... }:
let
  cfg = config.syncthing;
  devices = import ../syncthing-devices.nix;

  peers = lib.remove cfg.device (lib.attrNames devices);

  # Staggered versioning, history kept outside the synced folder: on the server `/var/lib/data` is
  # restic's one source path, and inside the folder snapshots would sync to every peer.
  versioning = {
    type = "staggered";
    params = {
      maxAge = "2592000";
      cleanupIntervalS = "3600";
    };
  }
  // lib.optionalAttrs (cfg.versioningPath != null) { fsPath = cfg.versioningPath; };
in
{
  options.syncthing = {
    device = lib.mkOption {
      type = lib.types.str;
      description = "This host's key in `modules/syncthing-devices.nix`; the folder is shared with every other device in that table.";
    };
    vaultPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Sync/vault";
      description = "Directory holding the vault ciphertext. Under ~/Sync on laptops: outside the TCC-protected folders on macOS, and never shared into the Linux agent VM.";
    };
    versioningPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/syncthing-versions/vault";
      description = "Where Syncthing keeps file versions. Defaults outside the synced folder, so the version history is neither synced to every peer nor inside restic's source path; the server overrides it with its own path outside `/var/lib/data`.";
    };
  };

  config = {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.device devices;
        message = "syncthing.device (${cfg.device}) needs its ID in modules/syncthing-devices.nix before Syncthing can run here; the local device is part of the config Syncthing writes.";
      }
    ];

    services.syncthing = {
      enable = true;
      # Declarative only: UI changes do not survive the next activation.
      overrideDevices = true;
      overrideFolders = true;
      settings = {
        # Relays stay on: laptops are not always on the server's network.
        options.relaysEnabled = true;
        devices = lib.mapAttrs (name: id: { inherit id name; }) devices;
        folders.vault = {
          id = "vault";
          label = "Vault";
          path = cfg.vaultPath;
          type = "sendreceive";
          devices = peers;
          # Hourly full scan still runs because some changes bypass inotify.
          fsWatcherEnabled = true;
          rescanIntervalS = 3600;
          # Cryptomator stores no permissions, so differing umasks would churn permission-only changes each rescan.
          ignorePerms = true;
          inherit versioning;
        };
      };
    };
  };
}
