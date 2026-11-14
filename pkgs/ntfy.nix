# The ntfy client, pinned to the server's version (smores56/sdlc#649).
#
# `ntfy-sh` in the pinned nixpkgs is 2.26.0 against a 2.37.2 server, and the
# client refuses a server whose protocol it does not know. Building from source
# would mean a vendorHash over a 30 MB Go tree, so this consumes the release's
# own static binary -- the pattern `pkgs/tutabridge.nix` uses. Bump the version
# and both hashes together from the release's `checksums.txt`:
#
#   https://github.com/binwiederhier/ntfy/releases/download/v<version>/checksums.txt
#
# The binary is CGO-free and static; `autoPatchelfHook` is here so a future
# release that is not fails at build time instead of at first run.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
let
  version = "2.37.2";
  srcs = {
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-5n9T1/vtUpuD+vOZO1hBEJIe81Z7CsCwM8aRCHmk/9E=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-1EDmlnVfIDJZK6ZFaZX3qfBLjEfSiNLj0s/7w9U4MfY=";
    };
  };
  target =
    srcs.${stdenv.hostPlatform.system}
      or (throw "ntfy: no pinned release for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ntfy";
  inherit version;

  src = fetchurl {
    url = "https://github.com/binwiederhier/ntfy/releases/download/v${version}/ntfy_${version}_linux_${target.arch}.tar.gz";
    inherit (target) hash;
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  # The tarball's single top-level directory becomes sourceRoot.
  installPhase = ''
    runHook preInstall

    install -Dm755 ntfy $out/bin/ntfy
    install -Dm644 LICENSE $out/share/doc/ntfy/LICENSE

    runHook postInstall
  '';

  meta = {
    description = "Send push notifications to your phone or desktop via PUT/POST";
    homepage = "https://ntfy.sh";
    changelog = "https://github.com/binwiederhier/ntfy/releases/tag/v${version}";
    license = lib.licenses.asl20;
    mainProgram = "ntfy";
    platforms = builtins.attrNames srcs;
    maintainers = [ ];
  };
})
