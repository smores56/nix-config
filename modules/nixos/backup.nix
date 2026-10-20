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
          description = "rclone config holding the offsite remote (mode 0600, owned by root). Read at runtime; never placed in the Nix store.";
        };
        remote = lib.mkOption {
          type = lib.types.str;
          default = "proton";
          description = "rclone remote name for offsite mirrors, e.g. \"proton\".";
        };
        datasets = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                driver = lib.mkOption {
                  type = lib.types.enum [
                    "rclone"
                    "restic"
                  ];
                  default = "rclone";
                  description = "Which backup driver owns this dataset. `rclone` is the legacy mirror/copy pipeline; `restic` is the local restic repo plus Proton byte-copy implemented in modules/nixos/backup-restic.nix.";
                };
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
                  description = "Shell snippet run before the copy (driver = \"rclone\" only). Its env exposes BACKUP_DATE, BACKUP_CURRENT, BACKUP_SOURCE.";
                };
                postgres = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether this dataset has a generated PostgreSQL dump pre-unit: puts the server's package on the backup unit PATH, orders it after postgresql.service, and starts the dump unit first. Both drivers generate one; restic writes the documented plain-SQL dump into its staging directory.";
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
                  description = "Exclude patterns passed to the driver (rclone globs or restic patterns) so they stay out of the backup. Defaults to dropping regenerable caches at the source root and nested, plus a source-root rclone.conf copy; a credential-shaped file elsewhere in the tree is still copied unless you add it here.";
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
                repository = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Local restic repository for driver = \"restic\". Defaults to <mountPoint>/restic/<Name>.";
                };
                passwordFile = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Optional override for the restic repository password file (driver = \"restic\"). Defaults to <repository>/password, which is copied with the repository, so a surviving copy is always decryptable. The sops restic-password file is only an optional seed/backup copy.";
                };
                protonPath = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Path under the rclone remote that receives the byte copy of the restic repository. Defaults to restic/<Name>. The copy is append-only: never synced and never pruned.";
                };
                retention = lib.mkOption {
                  type = lib.types.submodule {
                    options = {
                      daily = lib.mkOption {
                        type = lib.types.int;
                        default = 7;
                        description = "Snapshots kept by the daily retention rule.";
                      };
                      weekly = lib.mkOption {
                        type = lib.types.int;
                        default = 8;
                        description = "Snapshots kept by the weekly retention rule.";
                      };
                      monthly = lib.mkOption {
                        type = lib.types.int;
                        default = 24;
                        description = "Snapshots kept by the monthly retention rule.";
                      };
                      yearly = lib.mkOption {
                        type = lib.types.int;
                        default = 3;
                        description = "Snapshots kept by the yearly retention rule.";
                      };
                    };
                  };
                  default = { };
                  description = "restic forget/prune retention (driver = \"restic\"). Applied locally after each backup; Proton is never pruned.";
                };
                check = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Run restic check after each backup and, when fullCheckSchedule is set, a read-data-subset check on that calendar (driver = \"restic\").";
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
          description = "Datasets backed up onto the disk. `driver = \"rclone\"` uses the generic rclone 3-2-1 mirror; `driver = \"restic\"` uses a local restic repository plus a Proton byte copy.";
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
