{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.dotfiles;
  system = pkgs.stdenv.hostPlatform.system;

  # Upstream's Nix build compiles the bundled whisper.cpp/ggml unoptimised, so a
  # single phrase decode costs ~6x native whisper.cpp and the phrase-level
  # streaming only lands when recording stops. The toolchain file pinned below
  # is forwarded by whisper-rs-sys to its cmake invocation and turns the Release
  # build and SIMD paths back on (12.5s -> 2.1s for one 11.2s phrase).
  whisrs = inputs.whisrs.packages.${system}.default.overrideAttrs (old: {
    env = (old.env or { }) // {
      CMAKE_TOOLCHAIN_FILE = "${./whisrs-ggml.cmake}";
    };
  });

  # whisper.cpp base.en GGML weights for the local backend. Neither nixpkgs nor
  # sherpa-onnx ship a whisper.cpp model set, and the daemon would otherwise
  # download the file into $HOME on first run; pinning it keeps the config
  # pointing at an immutable store path.
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

  # Generated and read-only because whisrs anticipates Nix-templated configs.
  # `whisrs config` and `whisrs setup` rewrite this file and will fail against
  # the store symlink; edit this expression instead. Keep secrets (API keys) out:
  # the store path is world-readable.
  # The silence auto-stop is raised well above the 2s default (0 would stop on
  # the first silent sample, it does not disable it) so a thinking pause does
  # not end the session mid-dictation.
  configFile = pkgs.writeText "whisrs-config.toml" ''
    [general]
    backend = "local-whisper"
    language = "en"
    silence_timeout_ms = 30000
    notify = true
    audio_feedback = true

    [audio]
    device = "default"

    [input]
    backend = "auto"
    key_delay_ms = 2

    [local-whisper]
    model_path = "${whisperModel}/ggml-base.en.bin"
    segmentation = "silence"
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
      whisrs
      mdStructure
    ];

    xdg.configFile."whisrs/config.toml".source = configFile;

    # The daemon tracks the focused window through the compositor env; keep it
    # in the graphical session so early key presses are not dropped.
    systemd.user.services.whisrsd = {
      Unit = {
        Description = "whisrs dictation daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ config.wayland.systemd.target ];
      };

      Service = {
        ExecStart = "${whisrs}/bin/whisrsd";
        Restart = "on-failure";
        RestartSec = 3;
        PassEnvironment = [
          "NIRI_SOCKET"
          "WAYLAND_DISPLAY"
          "DISPLAY"
          "XDG_SESSION_TYPE"
          "XDG_CURRENT_DESKTOP"
          "XDG_RUNTIME_DIR"
        ];
      };

      Install.WantedBy = [ config.wayland.systemd.target ];
    };

    programs.niri.settings.binds."Mod+Shift+D".action.spawn = [
      "${whisrs}/bin/whisrs"
      "toggle"
    ];

    # Cleans the current selection in place; md-structure's non-zero exit on
    # unselected/degenerate input leaves the buffer untouched.
    programs.helix.settings.keys.normal.space.m = ":pipe md-structure";
  };
}
