{ ... }: {
  # Use Hyprland as the window manager
  programs.hyprland.enable = true;

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

      defaultSession = "hyprland";
    };
  };
}
