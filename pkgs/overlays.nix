# Package overlays applied to every host's nixpkgs: pins and local derivations
# that the pinned nixpkgs lacks or ships too old.
{ inputs }:
let
  inherit (inputs) niri concord;
  inherit (inputs.nixpkgs) lib;
in
system: [
  niri.overlays.niri
  (final: prev: {
    googlesans-code = prev.stdenv.mkDerivation (finalAttrs: {
      pname = "googlesans-code";
      version = "7.000";

      src = prev.fetchFromGitHub {
        owner = "googlefonts";
        repo = "googlesans-code";
        tag = "v${finalAttrs.version}";
        hash = "sha256-XjsjBMCA1RraXhQiNq/D0mb//VnRKOWl1X4XpGzifNA=";
      };

      nativeBuildInputs = [ prev.fontc ];

      buildPhase = ''
        runHook preBuild

        mkdir -p fonts/variable
        fontc sources/GoogleSansCode.glyphspackage --flatten-components --decompose-transformed-components --output-file "fonts/variable/GoogleSansCode[MONO,wght].ttf"
        fontc sources/GoogleSansCode-Italic.glyphspackage --flatten-components --decompose-transformed-components --output-file "fonts/variable/GoogleSansCode-Italic[MONO,wght].ttf"

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/share/fonts/googlesans-code
        cp fonts/variable/* $out/share/fonts/googlesans-code/

        runHook postInstall
      '';

      meta = {
        description = "Google Sans Code font family";
        homepage = "https://github.com/googlefonts/googlesans-code";
        changelog = "https://github.com/googlefonts/googlesans-code/blob/${finalAttrs.src.tag}/CHANGELOG.md";
        license = lib.licenses.ofl;
        maintainers = with lib.maintainers; [ shiphan ];
        platforms = lib.platforms.all;
      };
    });

    concord = concord.packages.${system}.default;

    # Agent sandbox: 0.12.0 fixes CVE-2026-87766 (setup-time symlink
    # traversal). The pinned nixpkgs ships 0.11.2.
    bubblewrap = inputs.nixpkgs-unstable.legacyPackages.${system}.bubblewrap;

    # The pinned nixpkgs ships bitwarden-desktop 2026.6.1 on electron_39,
    # which the security policy marks EOL (anything below 41). Unstable
    # carries 2026.9.0 on electron_43.
    bitwarden-desktop = inputs.nixpkgs-unstable.legacyPackages.${system}.bitwarden-desktop;

    # The pinned nixpkgs ships tutanota-desktop 355.260710.0 and the Tuta
    # server answers it with "Update needed"; 362.261023.2 is the current
    # release. Pinned here rather than following nixpkgs-unstable, which is
    # on 359 and whose bump would also move bubblewrap, bitwarden-desktop
    # and niri.
    tutanota-desktop =
      let
        pname = "tutanota-desktop";
        version = "362.261023.2";
        src = prev.fetchurl {
          url = "https://github.com/tutao/tutanota/releases/download/tutanota-desktop-release-${version}/${pname}-linux.AppImage";
          hash = "sha256-Slvei8P3bB+bDc0qzC5G468qtFQGlDV7WhoFVi85ZJ8=";
        };
        appimageContents = prev.appimageTools.extract { inherit pname version src; };
      in
      prev.appimageTools.wrapType2 {
        inherit pname version src;
        nativeBuildInputs = [ prev.makeWrapper ];

        extraInstallCommands = ''
          install -Dm 444 ${appimageContents}/tutanota-desktop.desktop -t $out/share/applications
          cp -r ${appimageContents}/usr/share/icons/. $out/share/icons

          substituteInPlace $out/share/applications/tutanota-desktop.desktop \
            --replace 'Exec=AppRun' 'Exec=${pname}'

          wrapProgram $out/bin/tutanota-desktop \
            --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"
        '';
      };

    # YubiKey FIDO2 note: OpenSSH's libfido2 lists the same token twice
    # (USB HID + PC/SC). Do not override libfido2/openssh here: changing
    # either hash cascades through qtwebengine, KDE, and PySide and forces
    # hours of source builds that the binary cache cannot satisfy. The
    # fido2 module wraps ssh-sk-helper with a no-PC/SC libfido2 instead.

    # doccstat/pam_rssh adds the user-presence flag check (upstream issue
    # #38), so sudo rejects a touchless signature even from a compromised
    # agent. The fork vendors its agent dependency, so no submodules. This is
    # a full buildRustPackage definition because overrideAttrs cannot
    # recompute cargoDeps after cargoHash changes.
    pam_rssh = prev.rustPlatform.buildRustPackage (finalAttrs: {
      pname = "pam_rssh";
      version = "unstable-2026-10-28";
      src = prev.fetchFromGitHub {
        owner = "doccstat";
        repo = "pam_rssh";
        rev = "116992cdae05728abf19ea0d81f264d50dd0910e";
        hash = "sha256-v9/WuYAlSXGrQ+c7K+pdFr3BhG9ZtprvYYJL540EbDA=";
        fetchSubmodules = false;
      };
      cargoHash = "sha256-gph4kAScKjFg1KsPb98dDg3uDeHBagM5PqkhGYkIVvg=";

      postPatch = ''
        substituteInPlace src/auth_keys.rs \
          --replace '/bin/echo' '${prev.coreutils}/bin/echo' \
          --replace '/bin/false' '${prev.coreutils}/bin/false'
      '';

      nativeBuildInputs = [
        prev.pkg-config
        prev.libclang
      ];
      buildInputs = [
        prev.openssl
        prev.pam
      ];
      env = {
        USER = "nixbld";
        LIBCLANG_PATH = "${prev.libclang.lib}/lib";
        BINDGEN_EXTRA_CLANG_ARGS = "-I${prev.glibc.dev}/include";
      };

      checkFlags = [
        # Fails because it tries finding authorized_keys in /home/$USER.
        "--skip=tests::parse_user_authorized_keys"
        # Skip unsupported DSA keys since OpenSSH v10.
        "--skip=sign_verify::test_dsa_sign_verify"
      ];

      nativeCheckInputs = [ prev.openssh ];

      preCheck = ''
        export HOME=$(mktemp -d)
        mkdir $HOME/.ssh
        ssh-keygen -q -N "" -t ecdsa -b 521 -f $HOME/.ssh/id_ecdsa521
        ssh-keygen -q -N "" -t ecdsa -b 384 -f $HOME/.ssh/id_ecdsa384
        ssh-keygen -q -N "" -t ecdsa -b 256 -f $HOME/.ssh/id_ecdsa256
        ssh-keygen -q -N "" -t ed25519 -f $HOME/.ssh/id_ed25519
        ssh-keygen -q -N "" -t rsa -f $HOME/.ssh/id_rsa
        export SSH_AUTH_SOCK=$HOME/ssh-agent.sock
        eval $(ssh-agent -a $SSH_AUTH_SOCK)
        ssh-add $HOME/.ssh/id_ecdsa521
        ssh-add $HOME/.ssh/id_ecdsa384
        ssh-add $HOME/.ssh/id_ecdsa256
        ssh-add $HOME/.ssh/id_ed25519
        ssh-add $HOME/.ssh/id_rsa
      '';

      meta = {
        description = "PAM module for authenticating via ssh-agent, written in Rust (doccstat fork with UP check)";
        homepage = "https://github.com/doccstat/pam_rssh";
        license = prev.lib.licenses.mit;
        platforms = prev.lib.platforms.linux;
        maintainers = with prev.lib.maintainers; [ xyenon ];
      };
    });

    # Upstream's flake recipe: dependencies are vendored and the main
    # package lives in ./app, so rename the produced binary.
    revdiff =
      let
        unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
        version = "1.13.0";
      in
      unstable.buildGoModule {
        pname = "revdiff";
        inherit version;
        src = unstable.fetchFromGitHub {
          owner = "umputun";
          repo = "revdiff";
          tag = "v${version}";
          hash = "sha256-qcah2Fx4u9AXEfb22R9BW3Rv9oYx+H8+KPGQVRjOr98=";
        };
        vendorHash = null;
        subPackages = [ "app" ];
        doCheck = false;
        env.CGO_ENABLED = 0;
        ldflags = [
          "-s"
          "-w"
          "-X main.revision=${version}"
        ];
        postInstall = ''
          mv $out/bin/app $out/bin/revdiff
        '';
        meta = {
          description = "TUI for reviewing diffs, files, and documents with inline annotations";
          homepage = "https://github.com/umputun/revdiff";
          changelog = "https://github.com/umputun/revdiff/blob/v${version}/CHANGELOG.md";
          license = lib.licenses.mit;
          mainProgram = "revdiff";
          platforms = lib.platforms.linux ++ lib.platforms.darwin;
        };
      };
  })
]
