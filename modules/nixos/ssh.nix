{ config, lib, ... }:
let
  keysFile = builtins.fetchurl {
    url = "https://github.com/smores56.keys";
    sha256 = "0xjnfsiwynd8wl3jmfgjzndfh4gk03cjfvxix2ql3h2k2ddddqm";
  };
  keys = builtins.filter (s: s != "") (lib.splitString "\n" (builtins.readFile keysFile));
in
{
  config = lib.mkIf config.dotfiles.exposeSsh {
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };

    users.users.smores.openssh.authorizedKeys.keyFiles = [ keysFile ];

    nix.sshServe.enable = true;
    nix.sshServe.keys = keys;
  };
}
