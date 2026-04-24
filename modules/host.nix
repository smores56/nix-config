{
  config,
  pkgs,
  lib,
  displayManager,
  exposeSsh,
  ...
}:
let
  cfg = config.dotfiles;

  displayManagerModules = {
    niri = [ ./nixos/niri.nix ];
  };

  hasGreeter = builtins.elem cfg.displayManager [ "niri" ];
in
{
  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  time.timeZone = "America/New_York";

  users.users.smores = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    shell = pkgs.fish;
  };

  services.displayManager.autoLogin = lib.mkIf (!hasGreeter) {
    enable = true;
    user = "smores";
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  programs.fish.enable = true;

  nixpkgs.config.allowUnfree = true;

  imports =
    [
      ./nixos
    ]
    ++ lib.optionals (displayManager != null) [ ./nixos/sound.nix ]
    ++ (if displayManager != null then (displayManagerModules.${displayManager} or [ ]) else [ ])
    ++ lib.optionals exposeSsh [ ./nixos/sshd.nix ./nixos/ssh-serve.nix ];
}
