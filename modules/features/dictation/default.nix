{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  # NVIDIA Nemotron streaming ASR (0.6B, 560ms chunks, int8) exported for
  # sherpa-onnx. Not in nixpkgs, so it is pinned as a fixed-output derivation:
  # reproducible, offline once built, and no copy into $HOME.
  nemotronStreamingEn = pkgs.stdenvNoCC.mkDerivation {
    pname = "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8";
    version = "2026-04-25";

    src = pkgs.fetchurl {
      url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2";
      hash = "sha256-eOK3n89ycVU6dEAqdrdxsJ6kARejlWann1IjWyPbY1g=";
    };

    nativeBuildInputs = [ pkgs.bzip2 ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      tar -xjf $src -C $out --strip-components=1
      runHook postInstall
    '';
  };
  # wtype needs no daemon and works on niri today; ydotool goes through
  # /dev/uinput and survives compositor virtual-keyboard regressions
  # (modules/nixos/dictation.nix provides the ydotoold service and group).
  dictate = pkgs.writeShellApplication {
    name = "dictate";
    runtimeInputs = with pkgs; [
      coreutils
      sherpa-onnx
      util-linux # flock, guarding the toggle decision
      wtype
      ydotool
    ];
    text =
      builtins.replaceStrings
        [ "@MODEL_DIR@" "@ALSA_PLUGIN_DIR@" ]
        [ "${nemotronStreamingEn}" "${pkgs.pipewire}/lib/alsa-lib" ]
        (builtins.readFile ./dictate.sh);
  };

  # `maki` is user-installed (~/.local/bin), not a nix package; the script
  # resolves it at runtime and buffers output so a failure keeps the selection.
  mdStructure = pkgs.writeShellApplication {
    name = "md-structure";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.replaceStrings
      [ "@PROMPT_FILE@" ]
      [ "${./md-structure.prompt.md}" ]
      (builtins.readFile ./md-structure.sh);
  };
in
{
  config = lib.mkIf cfg.wayland {
    home.packages = [
      dictate
      mdStructure
    ];

    programs.niri.settings.binds."Mod+Shift+D".action.spawn = [
      "${dictate}/bin/dictate"
      "toggle"
    ];

    # Cleans the current selection in place; md-structure's non-zero exit on
    # unselected/degenerate input leaves the buffer untouched.
    programs.helix.settings.keys.normal.space.m = ":pipe md-structure";
  };
}
