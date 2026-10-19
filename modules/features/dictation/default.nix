{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

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
    home.packages = [ mdStructure ];

    # The compositor owns the keybinding; Voxtype's evdev hotkey stays off so
    # no input-group membership or uinput access is needed. wtype/wl-clipboard
    # come from the module's wayland runtime path.
    services.voxtype = {
      enable = true;
      wayland.display = "wayland-1";

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

    programs.niri.settings.binds."Mod+Shift+D".action.spawn = [
      (lib.getExe pkgs.voxtype)
      "record"
      "toggle"
    ];

    # Cleans the current selection in place; md-structure's non-zero exit on
    # unselected/degenerate input leaves the buffer untouched.
    programs.helix.settings.keys.normal.space.m = ":pipe md-structure";
  };
}
