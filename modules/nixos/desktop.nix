{
  config,
  pkgs,
  lib,
  ...
}:
let
  # SteamVR's vrsetup.sh runs `pkexec setcap CAP_SYS_NICE=eip` on
  # vrcompositor-launcher from inside the Steam Runtime container, where pkexec
  # is not setuid. The prompt is shown, the call fails, and setup reports "user
  # declined superuser request". Apply the capability from the host instead, and
  # re-apply it when a SteamVR update replaces the binary.
  steamvrLauncher =
    "${config.users.users.${config.machine.username}.home}"
    + "/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher";
in
{
  config = lib.mkIf config.machine.graphical {
    hardware.bluetooth.enable = true;

    environment.systemPackages = [
      pkgs.playerctl
      pkgs.networkmanagerapplet
    ];

    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    services.gnome.gnome-keyring.enable = true;

    systemd.services.steamvr-setcap = {
      description = "Grant CAP_SYS_NICE to SteamVR's vrcompositor-launcher";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.libcap ];
      script = ''
        # The guard also stops the path unit from re-triggering on the xattr
        # write that setcap performs.
        if [ -f "${steamvrLauncher}" ] && ! getcap "${steamvrLauncher}" | grep -q cap_sys_nice; then
          setcap CAP_SYS_NICE=eip "${steamvrLauncher}"
        fi
      '';
    };
    systemd.paths.steamvr-setcap = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = steamvrLauncher;
    };
  };
}
