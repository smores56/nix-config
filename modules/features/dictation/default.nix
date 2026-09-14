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

  # Upstream's Nix build compiles the bundled ggml unoptimised, so a phrase
  # decode costs ~6x native whisper.cpp and phrase-level streaming degenerates
  # into batch. whisper-rs-sys forwards this toolchain file to cmake; see it for
  # the numbers and the SIMD flags.
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

    # Read-only by design: `whisrs config`/`setup` rewrite this file and fail
    # against the store symlink, so edit this expression instead (keep secrets
    # out — store paths are world-readable). Only non-default keys are set; the
    # silence timeout is raised because 0 stops on the first silent sample, not
    # disables it, so 30s keeps a thinking pause from ending a session.
    xdg.configFile."whisrs/config.toml".text = ''
      [general]
      backend = "local-whisper"
      language = "en"
      silence_timeout_ms = 30000
      audio_feedback = true

      [local-whisper]
      model_path = "${whisperModel}/ggml-base.en.bin"
    '';

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
