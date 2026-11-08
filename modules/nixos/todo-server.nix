# The smortress half of the todo sync. The vault Syncthing daemon carries the
# todo folder, so the server is an always-on peer without a second daemon or a
# user-level daemon that can read the human's home. An always-on bindfs mount
# maps the vault user's /var/lib/data/todo into the hidden XDG data path.
#
# The folder rides the vault daemon, so it starts only after the vault migration
# marker (/var/lib/vault-migrated) exists; without that marker neither the vault
# nor the todo folder syncs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  todoDevices = import ../todo-devices.nix;
  user = config.machine.username;
  home = "/home/${user}";
  mountpoint = "${home}/.local/share/todo";

  # Keep the real tree vault-owned. The mountpoint is root-owned 0555 while the
  # mount is down, so an unmounted write fails loudly instead of landing in the
  # shadow directory; a stale FUSE mount is detached before a remount.
  mount = pkgs.writeShellScript "todo-mount" ''
    set -eu
    if ${pkgs.util-linux}/bin/mountpoint -q "${mountpoint}"; then
      if ! ${pkgs.coreutils}/bin/stat "${mountpoint}" >/dev/null 2>&1; then
        ${pkgs.util-linux}/bin/umount -l "${mountpoint}" || true
      else
        exec ${pkgs.coreutils}/bin/sleep infinity
      fi
    fi
    ${pkgs.coreutils}/bin/install -d -m 0755 -o ${user} -g users ${home}/.local/share
    ${pkgs.coreutils}/bin/install -d -m 0555 -o root -g root "${mountpoint}"
    exec ${pkgs.bindfs}/bin/bindfs -f -u ${user} -g users --create-for-user=vault --create-for-group=vault /var/lib/data/todo "${mountpoint}"
  '';
in
{
  services.syncthing.settings.folders.todo = {
    id = "todo";
    label = "Todo";
    path = "/var/lib/data/todo";
    type = "sendreceive";
    devices = [ "phone" ] ++ lib.attrNames todoDevices;
    fsWatcherEnabled = true;
    rescanIntervalS = 3600;
    ignorePerms = true;
    versioning = {
      type = "staggered";
      params = {
        maxAge = "2592000";
        cleanupIntervalS = "3600";
      };
      fsPath = "/var/lib/syncthing-versions/todo";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/data/todo 0700 vault vault -"
    "d /var/lib/syncthing-versions/todo 0700 vault vault -"
  ];

  systemd.services.todo-mount = {
    description = "bindfs mount of the todo tree";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    requires = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/data" ];
    serviceConfig = {
      ExecStart = "${mount}";
      Restart = "always";
      RestartSec = 2;
    };
  };
}
