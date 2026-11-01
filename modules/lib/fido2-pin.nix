# Shared FIDO2 PIN plumbing. One implementation of "prompt once, verify, cache
# for the session" for the agent askpass, yk-ensure, and yk-login; the contract
# and its reasons live in fido2-pin.sh.
{ pkgs }:
let
  ensurePin = pkgs.writeShellApplication {
    name = "fido2-ensure-pin";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.fuzzel
      pkgs.gnused
      pkgs.libnotify
      pkgs.util-linux
      pkgs.yubikey-manager
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${./fido2-pin.sh} "$@"
    '';
  };
in
{
  inherit ensurePin;
}
