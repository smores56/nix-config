# Read-only Tuta calendar -> ICS renderer (smores56/sdlc#589).
#
# The default build is the ICS core: the strict event parser, the RFC 5545
# renderer and the fingerprint, with unit tests, and no network or Tuta
# dependency. The `sdk` passthru is the fetcher build.
#
# Why the fetcher is not built here: it links `tutanota`'s Rust SDK, and the
# path that works for calendar bodies is TutaBridge's *prepared* SDK — a pinned
# tutanota submodule plus `scripts/sdk-prepare.py`'s patch series (AEAD session
# and group reads), bindgen and the generated entity tree. None of that exists
# in this repository or in the Nix sandbox, and the crate carries no SDK path on
# purpose so the default lockfile stays vendorable. `passthru.sdk` is therefore
# a documented broken build: `nix build .#tuta-ics-sdk` fails at the unresolved
# `tutanota` import with the message below. The guest still runs the timer; it
# reports the missing fetcher as a calendar alert instead of a silent gap.
{
  lib,
  rustPlatform,
}:
let
  core = rustPlatform.buildRustPackage {
    pname = "tuta-ics";
    version = "0.1.0";

    src = lib.cleanSource ./.;

    cargoLock.lockFile = ./Cargo.lock;
    cargoBuildFlags = [
      "-p"
      "tuta-ics"
    ];
    # The pure half is the contract: parsing, rendering, escaping and folding.
    doCheck = true;
    cargoTestFlags = [
      "-p"
      "tuta-ics"
    ];

    meta = {
      description = "Read-only Tuta calendar to ICS renderer (core, no SDK)";
      homepage = "https://github.com/smores56/nix-config";
      license = lib.licenses.gpl3Plus;
      mainProgram = "tuta-ics";
      platforms = lib.platforms.unix;
    };
  };
in
core
// {
  passthru = (core.passthru or { }) // {
    sdk = core.overrideAttrs (old: {
      pname = "tuta-ics-sdk";
      buildFeatures = [ "sdk" ];
      meta = old.meta // {
        description = "Read-only Tuta calendar fetcher (needs the prepared Tuta SDK)";
        # Fails at the unresolved `tutanota` import: the SDK is not vendored.
        # To build it, add the prepared SDK to Cargo.toml, refresh Cargo.lock
        # and point `tutanota` at `sdk/generated/tuta-sdk/rust/sdk`; see
        # docs/kanbei-ingest-tuta.md.
        broken = true;
      };
    });
  };
}
