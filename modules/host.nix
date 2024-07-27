{ pkgs, nixos-cosmic, hostname, ... }: {
  nix.settings = {
    substituters = [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  system.stateVersion = "unstable";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = hostname;
  time.timeZone = "America/Los_Angeles";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.fish;
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = "smores";
  };

  programs.fish.enable = true;

  nixpkgs.config.allowUnfree = true;

  services.desktopManager.cosmic.enable = true;
  services.displayManager.cosmic-greeter.enable = true;

  imports = [
    ./nixos
    ./nixos/sound.nix
    ../hardware-configuration/${hostname}.nix
    nixos-cosmic.nixosModules.default
  ];
}
