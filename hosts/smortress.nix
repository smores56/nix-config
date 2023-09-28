{ config, ... }: {
  system.stateVersion = "23.05";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "smortress";
  time.timeZone = "America/Los_Angeles";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable OpenGL
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  # Install Nvidia drivers
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  imports = [
    # Generated with `sudo nixos-generate-config`
    /etc/nixos/hardware-configuration.nix
    ../modules/nixos
    ../modules/nixos/sound.nix
    ../modules/nixos/popos.nix
    ../modules/nixos/sshd.nix
  ];
}
