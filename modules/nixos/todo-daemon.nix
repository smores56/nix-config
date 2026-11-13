# The todo tree: one size-capped ext4 filesystem at /var/lib/data/todo, synced by
# the `vault` Syncthing instance as the `todo` folder.
#
# The image bounds the tree — a runaway capture cannot fill the root filesystem —
# and the mount also hides the plain directory an unmounted image would leave
# behind. Syncthing carries `RequiresMountsFor` on the mount; `td` goes through
# `todo-open`, which refuses an unmounted tree or a symlinked file.
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
  devices = import ../syncthing-devices.nix;

  dir = "/var/lib/data/todo";
  image = "/var/lib/todo.img";
  sizeMiB = 256;

  vault = config.users.users.vault;
  vaultGroup = config.users.groups.vault;
  owner = "${toString vault.uid}:${toString vaultGroup.gid}";

  # tuxedo reads this from ${XDG_CONFIG_HOME}/tuxedo/config.toml. `todo-open`
  # points XDG_CONFIG_HOME at the vault user's home, so the config has to be
  # readable there; the activation script reinstalls it on every switch.
  tuxedoConfig = pkgs.writeText "tuxedo-config.toml" ''
    theme = Terminal
  '';

  # Format the image once and hand its root to the vault user. When the image is
  # created, copy the current plain directory in: on the first activation that
  # directory is the only copy of the synced tree, and mounting an empty image
  # over it would let Syncthing propagate the deletions.
  imageInitText = ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.e2fsprogs
        pkgs.util-linux
      ]
    }
    img=${image}
    if [ -s "$img" ]; then
      # No grep here: the unit's PATH holds only coreutils/e2fsprogs/util-linux, so a
      # pipeline into grep failed with 127 and every switch rejected a valid image.
      if [ "$(blkid -o value -s TYPE "$img" 2>/dev/null || true)" = "ext4" ]; then
        exit 0
      fi
      echo "todo-image: $img is not an ext4 image; refusing to reformat it" >&2
      exit 1
    fi

    truncate -s ${toString sizeMiB}M "$img"
    chmod 0600 "$img"
    mkfs.ext4 -q -F -L todo "$img"

    mnt=$(mktemp -d /run/todo-image.XXXXXX)
    cleanup() {
      umount "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
    }
    trap cleanup EXIT
    mount -o loop "$img" "$mnt"

    if [ -d ${dir} ] && [ ! -L ${dir} ] && [ -n "$(ls -A ${dir})" ]; then
      cp -a ${dir}/. "$mnt"/
    fi
    chown ${owner} "$mnt"
    chmod 0700 "$mnt"
    [ -e "$mnt/todo.txt" ] || install -o ${toString vault.uid} -g ${toString vaultGroup.gid} -m 0600 /dev/null "$mnt/todo.txt"
    [ -e "$mnt/done.txt" ] || install -o ${toString vault.uid} -g ${toString vaultGroup.gid} -m 0600 /dev/null "$mnt/done.txt"

    umount "$mnt"
    rmdir "$mnt"
    trap - EXIT
  '';

  imageInit = pkgs.writeShellScript "todo-image-init" imageInitText;

  # tuxedo follows an existing symlink, and a symlinked todo.txt inside the
  # vault-owned tree would let the vault user's write land outside it. tuxedo has
  # no option for this, so the wrapper refuses the session instead.
  todoOpen = pkgs.writeShellApplication {
    name = "todo-open";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.tuxedo
      pkgs.util-linux
    ];
    text = ''
      dir=${dir}
      file=$dir/todo.txt

      for path in "$dir" "$file" "$dir/done.txt" "$dir/inbox.txt" \
        "$dir/inbox.txt.tuxedo-lock" "$dir/inbox.txt.tuxedo-staging"; do
        if [ -L "$path" ]; then
          echo "todo-open: refusing symlink $path" >&2
          exit 1
        fi
      done
      # An unmounted image leaves a plain directory behind the mountpoint; a write
      # there would vanish from Syncthing at the next mount.
      if ! mountpoint -q "$dir"; then
        echo "todo-open: $dir is not mounted; refusing to edit the shadow directory" >&2
        exit 1
      fi

      [ -e "$file" ] || install -m 0600 /dev/null "$file"

      # Keep everything tuxedo writes in the vault user's own home, never the
      # caller's (which vault cannot read).
      export HOME=${vault.home}
      export XDG_CONFIG_HOME=$HOME/.config
      export XDG_CACHE_HOME=$HOME/.cache

      exec ${lib.getExe pkgs.tuxedo} "$file"
    '';
  };
in
{
  assertions = [
    {
      assertion = lib.any (m: m.where == dir) config.systemd.mounts;
      message = "${dir} must be its own filesystem (systemd.mounts), not a plain directory; an unmounted tree would silently absorb vault writes.";
    }
    {
      assertion = !(lib.any (r: lib.hasPrefix "d ${dir} " r) config.systemd.tmpfiles.rules);
      message = "do not create ${dir} with tmpfiles: the mount unit owns that path and a tmpfiles directory would become the writable shadow of a failed mount.";
    }
    {
      assertion = lib.hasInfix "chown ${owner}" imageInitText;
      message = "the todo filesystem root must be owned by vault (${owner}), the uid Syncthing and td run as.";
    }
  ];

  services.syncthing.settings.folders.todo = {
    id = "todo";
    label = "Todo";
    path = dir;
    type = "sendreceive";
    devices = lib.remove config.vaultSync.device (lib.attrNames devices);
    fsWatcherEnabled = true;
    rescanIntervalS = 3600;
    ignorePerms = true;
    # mkfs.ext4 creates it; syncing it would put an empty root-only directory on
    # every peer.
    ignorePatterns = [ "/lost+found" ];
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
    "f ${image} 0600 root root -"
    "d /var/lib/syncthing-versions/todo 0700 vault vault -"
  ];

  systemd.services = {
    todo-image = {
      description = "Create the size-capped todo filesystem image";
      after = [ "systemd-tmpfiles-setup.service" ];
      requires = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = imageInit;
      };
    };
  }
  // lib.optionalAttrs config.services.syncthing.enable {
    # The mount must exist before Syncthing opens the folder; with a broken mount
    # the daemon fails loudly instead of syncing the shadow directory. This merges
    # with the vault-sync module's stateDir entry.
    syncthing.unitConfig.RequiresMountsFor = [ dir ];
  };

  systemd.mounts = [
    {
      where = dir;
      what = image;
      type = "ext4";
      options = "loop,noatime,nosuid,nodev";
      wantedBy = [ "multi-user.target" ];
      # A .mount unit is ordered before local-fs.target by default, but this one must
      # wait for todo-image.service, which runs after systemd-tmpfiles-setup. That is
      # an ordering cycle, and systemd breaks it by deleting a required job (in the
      # cutover boot it deleted systemd-tmpfiles-setup), so the mount, the vault's
      # todo folder, Syncthing and the kanbei prep that serves the tree stay down.
      # Drop the implicit ordering and keep the shutdown contract by hand.
      unitConfig.DefaultDependencies = false;
      conflicts = [ "umount.target" ];
      before = [ "umount.target" ];
      requires = [ "todo-image.service" ];
      after = [
        "local-fs.target"
        "todo-image.service"
      ];
      mountConfig.TimeoutSec = "60s";
    }
  ];

  system.activationScripts.todoTuxedoConfig = {
    deps = [ "users" ];
    text = ''
      install -d -o vault -g vault -m 0700 ${vault.home}/.config ${vault.home}/.config/tuxedo ${vault.home}/.cache
      install -o vault -g vault -m 0644 ${tuxedoConfig} ${vault.home}/.config/tuxedo/config.toml
    '';
  };

  environment.systemPackages = [ todoOpen ];
}
