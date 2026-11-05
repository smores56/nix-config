{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine;

  # Pinned so the config points at an immutable store path, not a first-run download.
  whisperModel = pkgs.stdenvNoCC.mkDerivation {
    pname = "whisper-cpp-ggml-base-en";
    version = "2026-09-14";

    src = pkgs.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
      hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
    };

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      install -Dm644 $src $out/ggml-base.en.bin
      runHook postInstall
    '';
  };

  voxtype = pkgs.voxtype.overrideAttrs (old: {
    env = (old.env or { }) // {
      CMAKE_TOOLCHAIN_FILE = "${./ggml-avx.cmake}";
    };
  });

  # Niri's wayland socket name varies per boot; the daemon runs wtype/wl-copy.
  voxtypeDaemon = pkgs.writeShellScript "voxtype-daemon" ''
    set -eu
    for socket in "''${XDG_RUNTIME_DIR:?}"/wayland-*; do
      if [ -S "$socket" ]; then
        export WAYLAND_DISPLAY="''${socket##*/}"
        break
      fi
    done
    exec ${lib.getExe voxtype} daemon
  '';
in
{
  config = lib.mkIf cfg.wayland {
    home.packages = [
      pkgs.wl-clipboard
      pkgs.wtype
    ];

    # The compositor owns the keybinding, so no input-group or uinput access is needed.
    services.voxtype = {
      enable = true;
      package = voxtype;

      settings = {
        hotkey.enabled = false;

        audio.feedback.enabled = true;

        whisper = {
          model = "${whisperModel}/ggml-base.en.bin";
          language = "en";
        };

        output = {
          mode = "type";
          fallback_to_clipboard = true;
        };
      };
    };

    # Upstream's default.target binding would start the graphical session (and niri)
    # at the greeter, since linger runs the user manager from boot.
    systemd.user.services.voxtype = {
      Unit = {
        PartOf = lib.mkForce [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Wants = [ "graphical-session.target" ];
      };

      Service.ExecStart = lib.mkForce voxtypeDaemon;
      Install.WantedBy = lib.mkForce [ "graphical-session.target" ];
    };

    programs.niri.settings.binds."Mod+Shift+D".action.spawn = [
      (lib.getExe voxtype)
      "record"
      "toggle"
    ];
  };
}
