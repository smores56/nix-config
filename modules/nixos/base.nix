{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
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
    shell = pkgs.${cfg.shell};
  };

  services.displayManager.autoLogin = lib.mkIf (!hasGreeter) {
    enable = true;
    user = "smores";
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  programs.${cfg.shell}.enable = true;
  nixpkgs.config.allowUnfree = true;
}
