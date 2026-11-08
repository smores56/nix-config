# The smorespro half of the todo sync: a user-level Syncthing daemon under its
# own XDG state, sharing ~/.local/share/todo with the phone and smortress. The
# common todo module supplies todo.sh and the td/te abbreviations.
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
in
{
  home.packages = [ pkgs.syncthing ];

  home.activation.todoFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -d "$HOME/Tasks" ] && [ ! -e "$HOME/.local/share/todo/todo.txt" ]; then
      echo "todo: move ~/Tasks into ~/.local/share/todo before switching (see docs/manual-steps.md)" >&2
      exit 1
    fi
    run ${pkgs.coreutils}/bin/mkdir -p "$HOME/.local/share/todo"
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
      devices = {
        phone = {
          id = devices.phone;
          name = "phone";
        };
        smortress = {
          id = devices.smortress;
          name = "smortress";
        };
      };
      folders.todo = {
        id = "todo";
        label = "Todo";
        path = "${home}/.local/share/todo";
        type = "sendreceive";
        devices = [
          "phone"
          "smortress"
        ];
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

  systemd.user.services.syncthing.Service.Environment = [
    "XDG_STATE_HOME=${stateHome}"
    "XDG_CONFIG_HOME=${stateHome}"
  ];
  systemd.user.services.syncthing-init.Service.Environment = [
    "XDG_STATE_HOME=${stateHome}"
    "XDG_CONFIG_HOME=${stateHome}"
  ];
}
