{ lib, ... }: {
  # Enable SSH server
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  users.users.smores = {
    openssh.authorizedKeys.keys = (import ../terminal/ssh/keys.nix { lib = lib; });
  };
}
