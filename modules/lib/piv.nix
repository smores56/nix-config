# The PIV agent's socket on each OS and the pre-connect wrapper that warms it
# (modules/features/piv-ensure.sh), shared by the hosts that log in with PIV.
{
  config,
  lib,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  yubikeyKeys = import ./yubikey-keys.nix;
  opensc = "${pkgs.opensc}/lib/opensc-pkcs11.so";
  macSock = "${config.home.homeDirectory}/.ssh/piv-agent.sock";

  # Spelled for ssh_config and for the shell; launchd cannot know the
  # per-session TMPDIR, so the Mac socket lives in ~/.ssh (0600, not a key).
  sock =
    if isLinux then
      {
        ssh = "\${XDG_RUNTIME_DIR}/piv-agent";
        sh = "\${XDG_RUNTIME_DIR:?}/piv-agent";
      }
    else
      {
        ssh = macSock;
        sh = macSock;
      };

  # Lives as long as the login session: tmpfs on Linux; on macOS the per-user
  # temp dir, emptied at each login by the piv-pin-wipe agent.
  cacheDir =
    if isLinux then "\${XDG_RUNTIME_DIR:?}/piv" else "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)piv";

  dialog = pkgs.writeShellApplication {
    name = "piv-dialog";
    runtimeInputs = [ pkgs.coreutils ] ++ lib.optional isLinux pkgs.fuzzel;
    text = ''exec ${pkgs.bash}/bin/bash ${../features/piv-dialog.sh} "$@"'';
  };
  cacheAskpass = pkgs.writeShellScript "piv-cache-askpass" ''exec ${pkgs.coreutils}/bin/cat "$PIV_PIN_FILE"'';

  ensureProxy = pkgs.writeShellApplication {
    name = "piv-ensure-proxy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.flock
      pkgs.gnused
      pkgs.openssh
      pkgs.yubikey-manager
    ];
    text = ''
      ${pkgs.bash}/bin/bash ${../features/piv-ensure.sh} "${sock.sh}" "${opensc}" "${cacheDir}" \
        ${lib.getExe dialog} ${cacheAskpass} ${
          lib.escapeShellArgs (map (k: pkgs.writeText "${k.key}.pub" k.pubkey) yubikeyKeys.piv)
        }
      exec "$@"
    '';
  };
in
{
  inherit
    sock
    opensc
    ensureProxy
    ;
}
