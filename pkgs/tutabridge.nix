# TutaBridge's headless CLI, pinned to one upstream release (smores56/sdlc#589).
#
# The bridge embeds Tuta's Rust SDK plus a series of patches applied by
# `scripts/sdk-prepare.py` against a pinned tutanota submodule. Building that in
# Nix would mean reproducing that preparation step and the SDK's bindgen
# toolchain, so the guest consumes the release's Linux CLI binary instead. The
# hash is the release's own `SHA256SUMS` entry:
#
#   https://github.com/spartanz51/tutabridge/releases/download/v0.2.0-rc.2/SHA256SUMS
#
# Bumping TutaBridge (required when Tuta raises its minimum client version) is
# one version + hash change here; see docs/kanbei-ingest-tuta.md.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  dbus,
  glibc,
  libgcc,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "tutabridge";
  version = "0.2.0-rc.2";

  src = fetchurl {
    url = "https://github.com/spartanz51/tutabridge/releases/download/v${finalAttrs.version}/tutabridge-linux-x86_64";
    hash = "sha256-r5Ez46jUYBCngxnBjSRHfadffSEMxzVLsDRZEbslyME=";
  };

  # The release asset is a single executable, not an archive.
  dontUnpack = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    dbus
    glibc
    libgcc
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ${finalAttrs.src} $out/bin/tutabridge
    runHook postInstall
  '';

  meta = {
    description = "Local IMAP/SMTP bridge for Tuta encrypted email (headless CLI)";
    homepage = "https://github.com/spartanz51/tutabridge";
    changelog = "https://github.com/spartanz51/tutabridge/releases/tag/v${finalAttrs.version}";
    # GPL-3.0-or-later because it links Tuta's GPLv3 Rust SDK.
    license = lib.licenses.gpl3Plus;
    mainProgram = "tutabridge";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
