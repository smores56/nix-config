# Plain-text todos: one todo.txt in ~/Tasks, edited with todo.sh or Helix and
# synced to the phone. The vault's Syncthing runs as the isolated `vault` user
# and cannot host a file the human edits, so this is a second, user-level
# daemon with its own ports and identity. The phone runs Syncthing-Fork and
# 0x54ask; see docs/manual-steps.md ("todo.txt").
{
  config,
  lib,
  pkgs,
  ...
}:
let
  devices = import ../syncthing-devices.nix;
  home = config.home.homeDirectory;
  identity = "${home}/.local/state/syncthing-todo-identity";

  # The migration copied the old user Syncthing identity into the vault
  # service, so starting in the default ~/.local/state/syncthing would reuse
  # the vault daemon's device ID. Generate a separate identity and install it
  # before the service starts; this replaces home-manager's own copyKeys hook.
  prepareIdentity = pkgs.writeShellScript "todo-syncthing-identity" ''
    set -eu
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/syncthing"
    if [ ! -e "${identity}/cert.pem" ] || [ ! -e "${identity}/key.pem" ]; then
      ${lib.getExe pkgs.syncthing} generate --home "${identity}" --no-port-probing
    fi
    ${pkgs.coreutils}/bin/install -dm700 "$state"
    ${pkgs.coreutils}/bin/install -Dm400 "${identity}/cert.pem" "$state/cert.pem"
    ${pkgs.coreutils}/bin/install -Dm400 "${identity}/key.pem" "$state/key.pem"
  '';
in
{
  home.packages = [
    pkgs.todo-txt-cli
    pkgs.syncthing
  ];

  # todo.sh looks here by default; the package's own config under $out/etc is
  # never consulted. The activation only creates missing files, so a rebuild
  # never overwrites the synced list.
  xdg.configFile."todo/config".text = ''
    export TODO_DIR="$HOME/Tasks"
    export TODO_FILE="todo.txt"
    export DONE_FILE="done.txt"
    export REPORT_FILE="report.txt"
  '';
  home.sessionVariables.TODOTXT_CFG_FILE = "${config.xdg.configHome}/todo/config";

  home.activation.todoFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.coreutils}/bin/mkdir -p "$HOME/Tasks"
    run ${pkgs.coreutils}/bin/touch "$HOME/Tasks/todo.txt" "$HOME/Tasks/done.txt"
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
        ];
        localAnnouncePort = 21028;
        localAnnounceMCAddr = "[ff12::8384]:21028";
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
        # Seeded before the first sync; a conflict is a normal file the phone
        # app merges, and the version set keeps 30 days outside the tree.
        versioning = {
          type = "staggered";
          params = {
            maxAge = "2592000";
            cleanupIntervalS = "3600";
          };
          fsPath = "${home}/.local/state/syncthing-versions/todo";
        };
      };
    };
  };

  systemd.user.services.syncthing.Service.ExecStartPre = lib.mkForce "${prepareIdentity}";
}
