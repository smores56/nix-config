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
in
{
  config = lib.mkIf cfg.wayland {
    home.packages = [
      nemotronStreamingEn
      pkgs.sherpa-onnx
      # Text injection: wtype needs no daemon and works on niri today; ydotool
      # is the fallback against compositor protocol regressions and is enabled
      # system-side in modules/nixos/dictation.nix.
      pkgs.wtype
    ];
  };
}
