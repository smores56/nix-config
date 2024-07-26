{ pkgs, ... }: {
  system.stateVersion = "unstable";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "smorestux";
  time.timeZone = "America/Los_Angeles";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.fish;
  };

  services.xserver.displayManager.autoLogin = {
    enable = true;
    user = "smores";
  };

  programs.fish.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  imports = [
    # Generated with `sudo nixos-generate-config`
    /etc/nixos/hardware-configuration.nix
    ../modules/nixos
    ../modules/nixos/sound.nix
    ../modules/nixos/hyprland.nix
  ];
}
