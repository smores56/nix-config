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

  # Container mode shells out to `$TUTABRIDGE_ASSETS/bootstrap.sh`, which in turn
  # reads its key parameters and config template from beside itself. The release
  # asset is only the binary, so take the three helpers from the tagged source.
  bootstrap = fetchurl {
    url = "https://raw.githubusercontent.com/spartanz51/tutabridge/v${finalAttrs.version}/docker/bootstrap.sh";
    hash = "sha256-Mqf5MkvJsfs6YB6FnK1IkGQ4pFx1nbC4i7EkpsVChlI=";
  };
  gpgKeyParameters = fetchurl {
    url = "https://raw.githubusercontent.com/spartanz51/tutabridge/v${finalAttrs.version}/docker/gpg-key-parameters";
    hash = "sha256-1HqzAh3BJCYtTPvfqEz+xZ/cnBlbV3sD0whehGg/XUI=";
  };
  configTemplate = fetchurl {
    url = "https://raw.githubusercontent.com/spartanz51/tutabridge/v${finalAttrs.version}/docker/config.toml";
    hash = "sha256-175gTVozvfoz9PGNGZ3xzY2Sr288hficPzRpcKEY2Hc=";
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
    install -Dm755 ${finalAttrs.bootstrap} $out/lib/tutabridge/bootstrap.sh
    install -Dm644 ${finalAttrs.gpgKeyParameters} $out/lib/tutabridge/gpg-key-parameters
    install -Dm644 ${finalAttrs.configTemplate} $out/lib/tutabridge/config.toml
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
