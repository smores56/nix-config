# Plain-text todos: one todo.txt in ~/Tasks, edited with todo.sh or Helix and
# synced to the phone. The vault's Syncthing runs as the isolated `vault` user
# and cannot host a file the human edits, so this is a second, user-level
# daemon under its own XDG state; see docs/manual-steps.md ("todo.txt").
{
  config,
  lib,
  pkgs,
  ...
}:
let
  devices = import ../../syncthing-devices.nix;
  home = config.home.homeDirectory;
  stateHome = "${home}/.local/state/syncthing-todo";

  # The vault daemon and this one must not share a state directory: the old
  # user-level directory still holds the vault's migrated identity, and
  # vault-sync reads it as a recovery source. A private XDG home also keeps the
  # old config and index out of this daemon.
  syncthingEnv = [
    "XDG_STATE_HOME=${stateHome}"
    "XDG_CONFIG_HOME=${stateHome}"
  ];
in
{
  home.packages = [
    pkgs.todo-txt-cli
    pkgs.syncthing
  ];

  # todo.sh looks here by default; the package's own config under $out/etc is
  # never consulted. The activation only creates missing files, so a rebuild
  # never bumps the synced list's mtime.
  xdg.configFile."todo/config".text = ''
    export TODO_DIR="$HOME/Tasks"
    export TODO_FILE="todo.txt"
    export DONE_FILE="done.txt"
    export REPORT_FILE="report.txt"
  '';

  home.activation.todoFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.coreutils}/bin/mkdir -p "$HOME/Tasks"
    if [ ! -e "$HOME/Tasks/todo.txt" ]; then
      run ${pkgs.coreutils}/bin/touch "$HOME/Tasks/todo.txt"
    fi
    if [ ! -e "$HOME/Tasks/done.txt" ]; then
      run ${pkgs.coreutils}/bin/touch "$HOME/Tasks/done.txt"
    fi
  '';

  services.syncthing = {
    enable = true;
    # The vault daemon keeps the defaults (8384/22000/21027).
    guiAddress = "127.0.0.1:8385";
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      options = {
        listenAddresses = [
          "tcp://0.0.0.0:22001"
          "quic://0.0.0.0:22001"
          # The default listen set includes the relay client; an explicit set
          # must add it back or a phone behind CGNAT/VPN never connects.
          "dynamic+https://relays.syncthing.net/endpoint"
        ];
        # The vault daemon owns 21027 on this host; discovery is global/relay.
        localAnnounceEnabled = false;
        relaysEnabled = true;
      };
      devices.phone = {
        id = devices.phone;
        name = "phone";
      };
      folders.todo = {
        id = "todo";
        label = "Todo";
        path = "${home}/Tasks";
        type = "sendreceive";
        devices = [ "phone" ];
        fsWatcherEnabled = true;
        rescanIntervalS = 3600;
        ignorePerms = true;
        # A conflict is a normal file the phone app merges; the version set
        # keeps 30 days under this daemon's private state.
        versioning = {
          type = "staggered";
          params = {
            maxAge = "2592000";
            cleanupIntervalS = "3600";
          };
          fsPath = "${stateHome}/versions/todo";
        };
      };
    };
  };

  systemd.user.services.syncthing.Service.Environment = syncthingEnv;
  systemd.user.services.syncthing-init.Service.Environment = syncthingEnv;
}
