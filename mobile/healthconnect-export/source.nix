# Pinned source for the INTERNET-less healthconnect-export fork (smores56/sdlc#593).
#
# This is a source skeleton, not a build: the Android app is compiled and signed by hand
# (Android SDK + release keystore, `docs/kanbei-phone.md`), so nothing here is wired into
# the flake. The upstream side is pinned to the audited commit and the fork patch is
# applied on top; `mobile/healthconnect-export/verify-manifest.sh` is the gate that must
# pass before an APK is built.
{
  applyPatches,
  fetchFromGitHub,
  lib,
}:
let
  rev = "e33563e29b387c32d331215725dae46d1bebd6a2";
  upstream = fetchFromGitHub {
    owner = "nachojrs";
    repo = "healthconnect-export";
    inherit rev;
    hash = "sha256-7Lo5tQOMEe7MELuhG6EwnSm2fsS8iBDpy2SR0c0bMmE=";
  };
in
{
  inherit rev upstream;

  # The fork patch removes Drive/webhook code and the network permissions/dependencies.
  src = applyPatches {
    name = "healthconnect-export-fork-${lib.substring 0 7 rev}";
    src = upstream;
    patches = [ ./fork.patch ];
  };
}
