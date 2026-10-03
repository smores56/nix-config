# The local backup disk: a generic, versioned-snapshot target. This module owns
# only the mount; each backup feature writes into its own folder beneath it.
# Mounted with `nofail` so a missing/failed disk never blocks boot — the
# backup services declare `RequiresMountsFor`, so they fail loudly instead.
{ config, lib, ... }:
let
  cfg = config.dotfiles.backup;
in
{
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
