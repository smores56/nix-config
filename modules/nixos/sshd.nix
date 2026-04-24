{ ... }:
{
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  users.users.smores.openssh.authorizedKeys.keyFiles = [
    (builtins.fetchurl {
      url = "https://github.com/smores56.keys";
      sha256 = "0xjnfsiwynd8wl3jmfgjzndfh4gk03cjfvxix2ql3h2k2ddddqm";
    })
  ];
}
