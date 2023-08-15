{ ... }: {
  system.stateVersion = "23.05";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "smoresbook";
  time.timeZone = "America/Los_Angeles";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  imports = [
    # Generated with `sudo nixos-generate-config`
    /etc/nixos/hardware-configuration.nix
    ../../modules/nixos
    ../../modules/nixos/sound.nix
    ../../modules/nixos/hyprland.nix
  ];
}
