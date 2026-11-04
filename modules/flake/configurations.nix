{ inputs, mkPkgs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    concord
    stylix
    sops-nix
    disko
    ;
  inherit (inputs.nixpkgs) lib;

  localOverlays = system: [
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
  ];

  pkgsForSystem =
    system:
    mkPkgs system {
      overlays = localOverlays system;
    };

  homeModules = [
    ../options.nix
    ../home.nix
    niri.homeModules.niri
    noctalia.homeModules.default
    stylix.homeModules.stylix
    sops-nix.homeManagerModules.sops
  ];

  # providers.nix injects `_module.args.aiProviders` for maki and cloudflared.
  # Pure data — safe to import into NixOS evaluations too.
  nixosModules = [
    ../options.nix
    ../features/ai/providers.nix
    sops-nix.nixosModules.sops
    # Declarative disk layouts: a host with modules/hosts/<name>/disko.nix
    # derives its fileSystems from disko.devices (see AGENTS.md).
    disko.nixosModules.disko
  ];

  # Hosts are discovered from modules/hosts/<name>/; adding a host means adding
  # a directory (meta.nix + default.nix + hardware.nix), never editing this file.
  hostsDir = ../hosts;
  hostNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir hostsDir)
  );
  hostMeta =
    name:
    let
      metaPath = hostsDir + "/${name}/meta.nix";
      meta =
        if builtins.pathExists metaPath then
          import metaPath
        else
          throw "modules/hosts/${name}/ has no meta.nix (see AGENTS.md)";
      # Catch typos in the top-level keys: a misspelled `home`/`nixos` flag or
      # options section would otherwise be silently ignored.
      allowed = [
        "system"
        "username"
        "nixos"
        "home"
        "user"
        "homeOptions"
        "nixosOptions"
      ];
      unknown = builtins.filter (key: !(builtins.elem key allowed)) (builtins.attrNames meta);
    in
    if unknown != [ ] then
      throw "modules/hosts/${name}/meta.nix has unknown keys: ${lib.concatStringsSep ", " unknown}"
    else
      meta;

  # default.nix is data, not a module. `profiles` names the shared profiles
  # (they drive machine.graphical/wayland/workHost and the server-profile
  # assertion); `home` and `nixos` list modules that exist on that host alone,
  # such as a disk layout's LUKS options, a greeter, or a Darwin host's sops
  # keys. Host-local modules are not profiles: their names never reach
  # machine.profiles.
  hostDefault =
    name:
    let
      path = hostsDir + "/${name}/default.nix";
      m =
        if builtins.pathExists path then
          import path
        else
          throw "modules/hosts/${name}/ has no default.nix (see AGENTS.md)";
      allowed = [
        "profiles"
        "home"
        "nixos"
      ];
      unknown = builtins.filter (key: !(builtins.elem key allowed)) (builtins.attrNames m);
    in
    if unknown != [ ] then
      throw "modules/hosts/${name}/default.nix has unknown keys: ${lib.concatStringsSep ", " unknown}"
    else
      m;

  hostProfiles =
    name:
    map (p: {
      name = lib.removeSuffix ".nix" (baseNameOf (toString p));
      inherit p;
    }) (hostDefault name).profiles;

  profileModules =
    name: kind: lib.concatMap (profile: (import profile.p).${kind} or [ ]) (hostProfiles name);

  hostModules = name: (hostDefault name).nixos or [ ];
  hostHomeModules = name: (hostDefault name).home or [ ];

  hostModule = args: profileNames: {
    machine = {
      inherit (args) username system;
      nixos = args.nixos or false;
      profiles = profileNames;
    };
    user = args.user or { };
  };

  normalize =
    m:
    m
    // {
      username = m.username or "smores";
      system = m.system or "x86_64-linux";
    };

  mkHome =
    args:
    let
      inherit (args) system username;
      profiles = hostProfiles args.hostname;
      profileNames = map (p: p.name) profiles;
    in
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForSystem system;
      extraSpecialArgs = {
        inherit inputs;
      };
      modules =
        homeModules
        ++ profileModules args.hostname "home"
        ++ hostHomeModules args.hostname
        ++ [
          (hostModule args profileNames // (args.homeOptions or { }))
          {
            home.username = username;
            home.homeDirectory =
              if lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}";
          }
        ];
    };

  mkNixos =
    args:
    let
      inherit (args) system;
      profiles = hostProfiles args.hostname;
      profileNames = map (p: p.name) profiles;
    in
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        { nixpkgs.overlays = localOverlays system; }
      ]
      ++ nixosModules
      ++ profileModules args.hostname "nixos"
      ++ hostModules args.hostname
      ++ lib.optionals (builtins.elem "linux-desktop" profileNames) [ niri.nixosModules.niri ]
      # hardware.nix is optional so a host can be authored (meta.nix +
      # disko.nix) before nixos-anywhere generates it during the install; the
      # guard keeps the flake evaluable in that window (see AGENTS.md). Warn
      # loudly because a missing file means no kernel modules / microcode.
      ++ (
        if builtins.pathExists (hostsDir + "/${args.hostname}/hardware.nix") then
          [ (hostsDir + "/${args.hostname}/hardware.nix") ]
        else
          lib.warn
            "modules/hosts/${args.hostname}/hardware.nix is missing: the NixOS config has no hardware settings (nixos-anywhere generates it on install; see AGENTS.md)"
            [ ]
      )
      ++ lib.optional (builtins.pathExists (hostsDir + "/${args.hostname}/disko.nix")) (
        hostsDir + "/${args.hostname}/disko.nix"
      )
      ++ [
        (hostModule args profileNames // (args.nixosOptions or { }))
        { networking.hostName = args.hostname; }
      ];
    };
in
{
  flake = {
    # Every host directory under modules/hosts/ contributes its configs; the
    # meta.nix `nixos`/`home` flags say which. Hosts are discovered, so adding
    # one never touches this file.
    homeConfigurations = lib.listToAttrs (
      map (
        name:
        let
          m = normalize (hostMeta name);
        in
        lib.nameValuePair "${m.username}@${name}" (mkHome (m // { hostname = name; }))
      ) (lib.filter (name: (hostMeta name).home or false) hostNames)
    );
    nixosConfigurations = lib.listToAttrs (
      map (name: lib.nameValuePair name (mkNixos ((normalize (hostMeta name)) // { hostname = name; }))) (
        lib.filter (name: (hostMeta name).nixos or false) hostNames
      )
    );
  };
}
