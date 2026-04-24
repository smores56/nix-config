{ lib, ... }:
let
  keysFile = builtins.fetchurl {
    url = "https://github.com/smores56.keys";
    sha256 = "0xjnfsiwynd8wl3jmfgjzndfh4gk03cjfvxix2ql3h2k2ddddqm";
  };
  keys = builtins.filter (s: s != "") (lib.splitString "\n" (builtins.readFile keysFile));
in
{
  nix.sshServe.enable = true;
  nix.sshServe.keys = keys;
}
