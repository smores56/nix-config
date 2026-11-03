# Syncthing carries the Cryptomator vault between devices as ciphertext: the
# server only relays bytes, and each client unlocks the vault itself. Device IDs
# live in `modules/syncthing-devices.nix` (public keys, safe to commit).
#
# One device may unlock the vault at a time. Syncthing resolves a concurrent
# edit as a whole-file conflict, and two devices creating the same directory at
# once produce two `dir.c9r` values whose loser becomes an orphaned content
# directory that only Cryptomator's vault health check can recover.
{ config, lib, ... }:
let
  cfg = config.syncthing;
  devices = import ../syncthing-devices.nix;

  # The folder is shared with every known peer except this device, which
  # Syncthing rejects in a folder's device list.
  peers = lib.remove cfg.device (lib.attrNames devices);

  # Staggered versioning thins hourly→daily→weekly up to 30 days. Both hosts
  # keep the history outside the synced folder: on the server `/var/lib/data` is
  # restic's one source path, and on laptops anything inside the folder would be
  # synced to every peer, multiplying snapshots and contradicting the runbook.
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
    enable = lib.mkEnableOption "Syncthing sharing the Cryptomator vault as ciphertext";
    device = lib.mkOption {
      type = lib.types.str;
      description = "This host's key in `modules/syncthing-devices.nix`; the folder is shared with every other device in that table.";
    };
    vaultPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Sync/vault";
      description = "Directory holding the vault ciphertext. Under ~/Sync on laptops: outside the TCC-protected folders on macOS, and already masked from agent-sandbox.";
    };
    versioningPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/syncthing-versions/vault";
      description = "Where Syncthing keeps file versions. Defaults outside the synced folder, so the version history is neither synced to every peer nor inside restic's source path; the server overrides it with its own path outside `/var/lib/data`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.device devices;
        message = "syncthing.device (${cfg.device}) needs its ID in modules/syncthing-devices.nix before Syncthing is enabled here; the local device is part of the config Syncthing writes.";
      }
    ];

    services.syncthing = {
      enable = true;
      # Declarative only: the table and the folder below are the whole truth, so
      # a click in the UI does not survive the next activation.
      overrideDevices = true;
      overrideFolders = true;
      settings = {
        # Defaults carry the rest. Relays stay on: laptops are not always on the
        # same network as the server.
        options.relaysEnabled = true;
        devices = lib.mapAttrs (name: id: { inherit id name; }) devices;
        folders.vault = {
          id = "vault";
          label = "Cryptomator vault";
          path = cfg.vaultPath;
          type = "sendreceive";
          devices = peers;
          # The watcher is the recommended mode for a large tree; the hourly
          # full scan still runs because some changes bypass inotify.
          fsWatcherEnabled = true;
          rescanIntervalS = 3600;
          # Cryptomator stores no permissions of its own (cleartext attributes
          # come from the ciphertext file), so differing umasks would churn
          # permission-only changes on every rescan.
          ignorePerms = true;
          inherit versioning;
        };
      };
    };
  };
}
