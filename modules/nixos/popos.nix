{ pkgs, ... }: {
  services.xserver = {
    enable = true;

    # Configure keymap in X11
    layout = "us";
    xkbVariant = "";

    # Enable touchpad support
    libinput.enable = true;

    # Use GDM as the login manager
    displayManager = {
      gdm = {
        enable = true;
        debug = true;
        wayland = true;
        autoSuspend = false;
      };

      defaultSession = "gnome";
    };

    desktopManager = {
      gnome.enable = true;
    };
  };

  environment.gnome.excludePackages = (with pkgs; [
    gnome-photos
    gnome-tour
  ]) ++ (with pkgs.gnome; [
    cheese
    gnome-music
    gedit
    epiphany
    geary
    gnome-characters
    tali
    iagno
    hitori
    atomix
    yelp
    gnome-contacts
    gnome-initial-setup
  ]);

  environment.systemPackages = with pkgs; [
    gnome.gnome-tweaks
    gnomeExtensions.pop-shell
  ];
}
