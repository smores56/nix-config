{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.machine;
in
{
  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The server has no swap and the Immich/llama peaks caused three OOM kills in
  # 30 days. zram gives the kernel compressed headroom without a disk-backed
  # swap file; 25% leaves most RAM for the workloads.
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

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
    shell = pkgs.${config.user.shell};
  };

  # Removable-media helpers and FUSE.
  services = {
    devmon.enable = true;
    gvfs.enable = true;
    udisks2.enable = true;
  };
  environment.systemPackages = [
    pkgs.fuse
    # Kitty over SSH exports TERM=xterm-kitty; without the entry every
    # terminfo consumer (less, journalctl, systemctl status) aborts with
    # "'xterm-kitty': unknown terminal type."
    pkgs.kitty.terminfo
  ];

  # Flake support must be system-wide, not just in the user's
  # ~/.config/nix/nix.conf: root runs the flake apps (`sudo nix run
  # .#proton-auth`, `.#cloudflare-apply`, `nixos-rebuild --flake`) and would
  # otherwise need --extra-experimental-features on every invocation.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # The setuid fusermount3 wrapper in /run/wrappers/bin, which unprivileged FUSE
  # mounts (rclone, sshfs) need. Enabling it here keeps the helper independent of
  # gvfs happening to pull fuse in; proton-drive.nix adds user_allow_other.
  programs.fuse.enable = true;

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

  programs.${config.user.shell}.enable = true;
  nixpkgs.config.allowUnfree = true;

  # Keep user services running across logout (needed for user systemd units).
  system.activationScripts.linger = ''
    $DRY_RUN_CMD ${config.systemd.package}/bin/loginctl enable-linger ${cfg.username}
  '';
}
