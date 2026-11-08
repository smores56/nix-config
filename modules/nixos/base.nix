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

  # No swap, and Immich/llama peaks caused OOM kills; zram gives compressed headroom.
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

  time.timeZone = "America/New_York";

  # Stylix's GTK target and home-manager's gtk activation load dconf; without
  # the service the switch aborts on its D-Bus call on niri hosts.
  programs.dconf.enable = true;

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
    # Pin the uid: the pam_rssh socket path is derived from it.
    uid = 1000;
    description = "Sam Mohr";
    extraGroups = [
      "networkmanager"
      "wheel"
      "dialout"
    ];
    shell = pkgs.${config.user.shell};
    # User services (and anything a login shell would otherwise start) keep running
    # without a login session.
    linger = true;
  };

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
    # YubiKey PIV tooling (enrollment, pcscd below). FIDO2 credentials use USB
    # HID directly and need none of this.
    pkgs.opensc
    pkgs.p11-kit
    pkgs.yubico-piv-tool
    pkgs.yubikey-manager
  ];

  # `ykman piv` and pam_p11 reach the key through PC/SC; without pcscd they fail
  # with "PC/SC not available" even though FIDO2 works.
  services.pcscd.enable = true;

  # pcscd runs as the `pcscd` user (upstream unit). ccid's generic rule matches
  # ID_USB_INTERFACES, which is not always populated when it runs, leaving the
  # daemon with libusb_open: LIBUSB_ERROR_ACCESS and no readers. Match the
  # YubiKey vendor directly.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="1050", GROUP="pcscd", MODE="0660"
  '';

  # System-wide: root runs the flake apps (`sudo nix run .#cloudflare-apply`,
  # `nixos-rebuild --flake`).
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Unprivileged builds. The agent sandbox routes its `nix` through the daemon
  # (it binds the state dir read-only), and with an empty build group the daemon
  # would run those builders as root.
  nix.settings.build-users-group = "nixbld";

  # Weekly collection as root, keeping a 30-day rollback window. A user-level
  # timer cannot collect the store when only root is trusted; home-manager
  # generations are expired separately by services.home-manager.autoExpire.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Setuid fusermount3 so unprivileged FUSE mounts work (AppImages, gvfs),
  # independent of gvfs pulling fuse in.
  programs.fuse.enable = true;

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

  # Syncthing watches the vault tree; the default budget is too small for a tree
  # this size.
  boot.kernel.sysctl."fs.inotify.max_user_watches" = 204800;
}
