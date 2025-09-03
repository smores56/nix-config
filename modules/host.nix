{
  pkgs,
  nixos-cosmic,
  hostname,
  expose-ssh,
  display-manager,
  ...
}:
{
  nix.settings = {
    substituters = [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = hostname;
  time.timeZone = "America/New_York";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    shell = pkgs.fish;
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = "smores";
  };

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  programs.fish.enable = true;

  nixpkgs.config.allowUnfree = true;

  imports = [
    ./nixos
    ../hardware-configuration/${hostname}.nix
  ]
  ++ (if display-manager != null then [ ./nixos/sound.nix ] else [ ])
  ++ (
    if display-manager == "cosmic" then
      [
        nixos-cosmic.nixosModules.default
        {
          services.desktopManager.cosmic.enable = true;
          services.displayManager.cosmic-greeter.enable = true;
        }
      ]
    else
      [ ]
  )
  ++ (
    if expose-ssh then
      [
        ./nixos/sshd.nix
        ./nixos/ssh-serve.nix
      ]
    else
      [ ]
  );
}
