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

    nanobot = final.callPackage ./nanobot { inherit inputs; };

    letta = final.callPackage ./letta { inherit inputs; };

    # Fixes CVE-2026-87766 (setup-time symlink traversal).
    bubblewrap = inputs.nixpkgs-unstable.legacyPackages.${system}.bubblewrap;

    # The pinned nixpkgs' electron_39 build is EOL under the security policy.
    bitwarden-desktop = inputs.nixpkgs-unstable.legacyPackages.${system}.bitwarden-desktop;

    # The Tuta server rejects the pinned nixpkgs version ("Update needed"). Not following
    # nixpkgs-unstable: its bump would also move bubblewrap, bitwarden-desktop and niri.
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

    # nixpkgs-unstable carries Brave Origin; pin the current release so its
    # Chromium base matches Brave instead of the input's older version. Bump
    # version and both hashes from the release's brave-origin_*.deb assets.
    brave-origin =
      let
        unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
        version = "1.98.63";
        arch = if prev.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
      in
      if prev.stdenv.hostPlatform.isLinux then
        unstable.brave-origin.overrideAttrs (_: {
          inherit version;
          src = prev.fetchurl {
            url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_${arch}.deb";
            hash =
              if prev.stdenv.hostPlatform.isAarch64 then
                "sha256-8nkMT9jDBJ1H2u6TJ4f2Hq50B8LKMN5q6Dar9TV9n4s="
              else
                "sha256-7b2eyO1VmShI/2iJYX+V1OnvFiW9ouWKLSJv9WBNScg=";
          };
        })
      else
        unstable.brave-origin;

    # Do not override libfido2/openssh: the hash change cascades through qtwebengine, KDE, and PySide
    # into uncached source builds. The fido2 module wraps ssh-sk-helper with a no-PC/SC libfido2
    # instead (OpenSSH's libfido2 lists the same token twice: USB HID + PC/SC).

    # No nixpkgs package. The prebuilt tarball is the upstream-supported Linux path; keep the
    # daemon and CLI on one release so their IPC does not skew.
    nym-vpn-core = prev.stdenv.mkDerivation (finalAttrs: {
      pname = "nym-vpn-core";
      version = "2026.14.0";

      src = prev.fetchurl {
        url = "https://github.com/nymtech/nym-vpn-client/releases/download/nym-vpn-v${finalAttrs.version}/nym-vpn-core-v${finalAttrs.version}_linux_x86_64.tar.gz";
        hash = "sha256-6ciyQda54CBjA9OBJytCKq4jK5NLhchv5ymFLTxAGKg=";
      };

      sourceRoot = "${finalAttrs.pname}-v${finalAttrs.version}_linux_x86_64";

      nativeBuildInputs = [ prev.autoPatchelfHook ];

      buildInputs = [
        prev.stdenv.cc.cc.lib
        prev.libmnl
        prev.libnftnl
        prev.dbus
      ];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        # nym-vpnd resolves nym-socks5-proxy as its sibling. Skip nym-exclude: it is
        # setuid-root and only needed for Linux split tunneling.
        grep -aFq '${finalAttrs.version}' nym-vpnd
        grep -aFq '${finalAttrs.version}' nym-vpnc
        test -f nym-socks5-proxy
        install -m755 nym-vpnd nym-vpnc nym-socks5-proxy $out/bin/
        runHook postInstall
      '';

      meta = {
        description = "NymVPN daemon and CLI";
        homepage = "https://nym.com";
        license = prev.lib.licenses.gpl3Only;
        platforms = [ "x86_64-linux" ];
        mainProgram = "nym-vpnc";
      };
    });

    # Upstream ships one source tree as both a calibre plugin and a standalone CLI. The agent
    # VM uses the CLI, so patch only Royal Road to send the browser navigation headers its
    # Cloudflare rules require; the nixpkgs release is older and fails on current story pages.
    fanficfare = prev.python3Packages.buildPythonApplication rec {
      pname = "fanficfare";
      version = "4.63.0";
      pyproject = true;

      src = prev.fetchFromGitHub {
        owner = "JimmXinu";
        repo = "FanFicFare";
        rev = "v${version}";
        hash = "sha256-sYxOlTF20mx2q2ypLbO8f8c2jJXKVqI2H6+By4wjvxs=";
      };

      patches = [ ./fanficfare-secfetch.patch ];

      nativeBuildInputs = [ prev.python3Packages.setuptools ];

      propagatedBuildInputs = with prev.python3Packages; [
        apsw
        beautifulsoup4
        brotli
        chardet
        cloudscraper
        html2text
        html5lib
        requests
        requests-file
        urllib3
      ];

      doCheck = false;

      meta = {
        description = "Tool for downloading fanfiction to eBook formats";
        homepage = "https://github.com/JimmXinu/FanFicFare";
        license = prev.lib.licenses.gpl3;
        mainProgram = "fanficfare";
        platforms = prev.lib.platforms.unix;
      };
    };

    # Adds the user-presence check so sudo rejects a touchless signature even from a compromised
    # agent. Full buildRustPackage: overrideAttrs can't recompute cargoDeps after cargoHash changes.
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

    # Dependencies are vendored and the main package lives in ./app, so rename the binary.
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
