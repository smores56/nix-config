{ pkgs, ... }:
{
  # Enable touchpad support
  services.libinput.enable = true;

  services.displayManager.defaultSession = "gnome";

  services.xserver = {
    enable = true;

    # Configure keymap in X11
    xkb = {
      layout = "us";
      variant = "";
    };

    # Use GDM as the login manager
    displayManager = {
      gdm = {
        enable = true;
        debug = true;
        wayland = true;
        autoSuspend = false;
      };

    };

    desktopManager = {
      gnome.enable = true;
    };
  };

  environment.gnome.excludePackages =
    (with pkgs; [
      gnome-photos
      gnome-tour
      gedit
      cheese
      epiphany
      geary
      yelp
    ])
    ++ (with pkgs.gnome; [
      gnome-music
      gnome-characters
      tali
      iagno
      hitori
      atomix
      gnome-contacts
      gnome-initial-setup
    ]);

  environment.systemPackages = with pkgs; [
    gnome-tweaks
    gnomeExtensions.pop-shell
  ];
}
