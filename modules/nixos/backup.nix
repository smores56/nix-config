# The local backup disk: a generic, versioned-snapshot target. This module owns
# only the mount; each backup feature writes into its own folder beneath it.
# Mounted with `nofail` so a missing/failed disk never blocks boot — the
# backup services declare `RequiresMountsFor`, so they fail loudly instead.
{ config, lib, ... }:
let
  cfg = config.backup;
in
{
  options.backup = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "the local backup disk (versioned snapshot target)";
        mountPoint = lib.mkOption {
          type = lib.types.path;
          default = "/var/backup";
          description = "Where the backup disk is mounted. Tenants get their own folder beneath it.";
        };
        device = lib.mkOption {
          type = lib.types.str;
          default = "/dev/disk/by-label/backup";
          description = "Block device or by-label/by-uuid path of the backup disk.";
        };
        rcloneConfig = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/backup/rclone.conf";
          description = "rclone config holding the offsite remote (mode 0600, owned by root). Read at runtime; never placed in the Nix store. Only used when `remote` names an rclone remote; a path remote needs none.";
        };
        remote = lib.mkOption {
          type = lib.types.str;
          default = "proton";
          description = "Offsite target: an rclone remote name (e.g. \"proton\", written as `<remote>:<Name>`) or an absolute filesystem path (e.g. \"/srv/proton\", the Proton FUSE mount, written as `<path>/<Name>`).";
        };
        datasets = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                source = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Directory to back up. Defaults to /var/lib/media/<Name>.";
                };
                offsite = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Mirror the local copy to the remote (append-only).";
                };
                freshnessSeconds = lib.mkOption {
                  type = lib.types.int;
                  default = 93600;
                  description = "Maximum age of BACKUP-LAST-SUCCESS before the freshness alert fires, in seconds. Default 26h for a daily backup; set 8d for a weekly-only dataset.";
                };
                preBackup = lib.mkOption {
                  type = lib.types.nullOr lib.types.lines;
                  default = null;
                  description = "Shell snippet run before the copy. Its env exposes BACKUP_DATE, BACKUP_CURRENT, BACKUP_SOURCE.";
                };
                postgres = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether this dataset has a generated PostgreSQL dump pre-unit: puts the server's package on the backup unit PATH, orders it after postgresql.service, and starts the dump unit first.";
                };
                postgresDatabase = lib.mkOption {
                  type = lib.types.str;
                  default = "immich";
                  description = "Database dumped by the generated PostgreSQL pre-unit for this dataset.";
                };
                excludes = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  # `/.cache/**` is root-anchored and `**/.cache/**` is not
                  # (rclone's `**/` needs a preceding path segment), so a
                  # `.cache` at the source root needs the first pattern and
                  # a nested one the second; both are required.
                  default = [
                    "/.cache/**"
                    "**/.cache/**"
                    "/rclone.conf"
                  ];
                  description = "rclone exclude patterns kept out of both mirrors. Defaults to dropping regenerable caches at the source root and nested, plus a source-root rclone.conf copy; a credential-shaped file elsewhere in the tree is still copied unless you add it here.";
                };
                schedule = lib.mkOption {
                  type = lib.types.str;
                  default = "daily";
                  description = "systemd OnCalendar expression for the backup timer.";
                };
                timeout = lib.mkOption {
                  type = lib.types.str;
                  default = "12h";
                  description = "systemd TimeSpan cap on a run (TimeoutStartSec). Generous for the first seed run; shorten later.";
                };
                lockWait = lib.mkOption {
                  type = lib.types.str;
                  default = "20m";
                  description = "How long a run waits for the host-wide offsite lock before deferring. Offsite datasets serialize on that lock, and an off-hours or on-change run of another dataset can hold it for much longer than this, so the wait must be bounded well under `timeout`; a deferred run exits 75, which the unit treats as success, and the next timer run retries. \"0\" waits forever (manual seed runs).";
                };
                stallTimeout = lib.mkOption {
                  type = lib.types.str;
                  default = "30m";
                  description = "Abort and retry a transfer that makes no progress for this long (a wedged Proton upload never trips rclone's own timeout). Copy is resumable, so retrying is safe. \"0\" disables.";
                };
                fullCheckSchedule = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional systemd OnCalendar for an extra whole-mirror integrity check: runs the same dataset with --full-check so drift in old, unchanged files is still caught. null (the default) disables it; the normal schedule verifies only the files that changed.";
                };
                onChange = lib.mkOption {
                  type = lib.types.submodule {
                    options = {
                      enable = lib.mkEnableOption "queueing a backup shortly after the source changes";
                      debounce = lib.mkOption {
                        type = lib.types.str;
                        default = "15m";
                        description = "Quiet period after the last accepted change before one backup is queued, so an upload or import batch produces one run rather than many. The scheduled timer remains the guaranteed fallback.";
                      };
                      ignore = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [ ];
                        description = "Extra path components or shell glob patterns whose changes never trigger a run (for example derived directories that the dataset excludes such as `thumbs`). Built-in junk suffixes and hidden entries are always ignored.";
                      };
                    };
                  };
                  default = { };
                  description = "Trigger this dataset's existing backup unit on filesystem changes under `source` (inotify, recursive) in addition to the scheduled timer.";
                };
              };
            }
          );
          default = { };
          description = "Datasets backed up onto the disk by the generic rclone 3-2-1 mechanism.";
        };
      };
    };
    default = { };
    description = "Generic local backup disk; hosts mount it and backup features write beneath it.";
  };

  config = lib.mkIf cfg.enable {
    fileSystems.${cfg.mountPoint} = {
      inherit (cfg) device;
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
        "x-systemd.device-timeout=10"
      ];
    };
  };
}
