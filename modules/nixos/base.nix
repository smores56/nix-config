{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  time.timeZone = "America/New_York";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = lib.genAttrs [
    "LC_ADDRESS"
    "LC_IDENTIFICATION"
    "LC_MEASUREMENT"
    "LC_MONETARY"
    "LC_NAME"
    "LC_NUMERIC"
    "LC_PAPER"
    "LC_TELEPHONE"
    "LC_TIME"
  ] (_: "en_US.UTF-8");

  users.users.${cfg.username} = {
    isNormalUser = true;
    description = "Sam Mohr";
    extraGroups = [
      "networkmanager"
      "wheel"
      "dialout"
    ];
    shell = pkgs.${cfg.shell};
  };

  services.displayManager.autoLogin = lib.mkIf cfg.graphical {
    enable = true;
    user = cfg.username;
  };

  # Removable-media helpers and FUSE.
  services = {
    devmon.enable = true;
    gvfs.enable = true;
    udisks2.enable = true;
  };
  environment.systemPackages = [
    pkgs.fuse
  ];

  # Run dynamically-linked binaries that aren't patched for Nix.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libz
    libgcc
    ncurses
  ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  programs.${cfg.shell}.enable = true;
  nixpkgs.config.allowUnfree = true;

  # Keep user services running across logout (needed for user systemd units).
  system.activationScripts.linger = ''
    $DRY_RUN_CMD ${config.systemd.package}/bin/loginctl enable-linger ${cfg.username}
  '';
}
