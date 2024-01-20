{ ... }: {
  system.stateVersion = "unstable";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "campfire";
  time.timeZone = "America/Los_Angeles";

  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  programs.fish.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  imports = [
    # Generated with `sudo nixos-generate-config`
    /etc/nixos/hardware-configuration.nix
    ../modules/nixos
    ../modules/nixos/sshd.nix
    ../modules/nixos/ssh-serve.nix
  ];
}
