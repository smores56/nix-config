{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine;

  # whisper.cpp base.en weights for the local backend. Pinning them keeps the
  # config pointing at an immutable store path instead of downloading into
  # $HOME on first run.
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

  # Niri uses libwayland's first free socket, so the name is not stable across
  # boots. Discover it when the daemon starts; it is the process that later
  # runs wtype/wl-copy.
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

  mdStructure = pkgs.writeShellApplication {
    name = "md-structure";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.replaceStrings [ "@PROMPT_FILE@" ] [ "${./md-structure.prompt.md}" ] (
      builtins.readFile ./md-structure.sh
    );
  };
in
{
  config = lib.mkIf cfg.wayland {
    home.packages = [
      mdStructure
      pkgs.wl-clipboard
      pkgs.wtype
    ];

    # The compositor owns the keybinding; Voxtype's evdev hotkey stays off so
    # no input-group membership or uinput access is needed.
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

    systemd.user.services.voxtype = {
      Unit = {
        After = [ "graphical-session.target" ];
        Wants = [ "graphical-session.target" ];
      };

      Service.ExecStart = lib.mkForce voxtypeDaemon;
    };

    programs.niri.settings.binds."Mod+Shift+D".action.spawn = [
      (lib.getExe voxtype)
      "record"
      "toggle"
    ];

    # Cleans the current selection in place; md-structure's non-zero exit on
    # unselected/degenerate input leaves the buffer untouched.
    programs.helix.settings.keys.normal.space.m = ":pipe md-structure";
  };
}
