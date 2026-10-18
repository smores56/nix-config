{ inputs, nixpkgsFor, ... }:
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

  importTree = path: (inputs.import-tree path).imports;

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

      # See the nixpkgs-unstable input: rclone needs the protondrive fixes it
      # carries (1.75.1) for a trustworthy Proton mirror.
      rclone = inputs.nixpkgs-unstable.legacyPackages.${system}.rclone;

      # musikcube's macosmediakeys plugin crashes the classic ld64 on the
      # current nixpkgs pin (ld64 stubs-pass bug, unmerged nixpkgs#536365).
      # Link with LLVM ld64.lld on Darwin; Linux is unaffected.
      musikcube = prev.musikcube.overrideAttrs (
        old:
        lib.optionalAttrs final.stdenv.hostPlatform.isDarwin {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.llvmPackages.lld ];
          NIX_CFLAGS_LINK = "-fuse-ld=lld";
        }
      );
    })
  ];

  pkgsForSystem =
    system:
    import (nixpkgsFor system) {
      inherit system;
      config.allowUnfree = true;
      overlays = localOverlays system;
    };

  homeModules = [
    ../options.nix
    ../home.nix
  ]
  ++ importTree ../features
  ++ importTree ../desktop
  ++ [
    niri.homeModules.niri
    noctalia.homeModules.default
    stylix.homeModules.stylix
    sops-nix.homeManagerModules.sops
  ];

  # providers.nix injects `_module.args.aiProviders`, which options.nix's
  # computed defaults (e.g. dotfiles.defaultModel) depend on.  Pure data — safe
  # to import into NixOS evaluations too.
  nixosModules = [
    ../options.nix
    ../features/ai/providers.nix
    sops-nix.nixosModules.sops
    # Declarative disk layouts: a host with modules/hosts/<name>/disko.nix
    # derives its fileSystems from disko.devices (see AGENTS.md).
    disko.nixosModules.disko
  ]
  ++ importTree ../nixos;

  # Host-authored knobs a home configuration may pass. Read-only `dotfiles.*`
  # values are resolved in options.nix and cannot be set here.
  homeKnobs = {
    displayManager = "none";
    windowManager = "none";
    polarity = null;
    nixos = null;
    fingerprint = null;
    noSleep = null;
    calibre = null;
    photobucket = null;
    aiProfile = null;
    llm = null;
    workHost = null;
    brain = null;
  };
  # Every host-authored knob (the first `dotfiles` section in options.nix),
  # used to reject typos in a host's meta.nix. Keep in sync with options.nix.
  hostKnobs = [
    "displayManager"
    "windowManager"
    "polarity"
    "aiProfile"
    "shellAbbrs"
    "brain"
    "workHost"
    "username"
    "exposeSsh"
    "sshAuthorizedKeys"
    "nvidia"
    "llm"
    "search"
    "searchPort"
    "noSleep"
    "nixos"
    "fingerprint"
    "webProxy"
    "calibre"
    "navidrome"
    "photobucket"
    "immich"
    "backup"
    "notify"
  ];

  # Hosts are discovered from modules/hosts/<name>/; adding a host means adding
  # a directory (meta.nix + hardware.nix), never editing this file.
  hostsDir = ../hosts;
  hostNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir hostsDir)
  );
  hostMeta =
    name:
    let
      metaPath = hostsDir + "/${name}/meta.nix";
      m =
        if builtins.pathExists metaPath then
          import metaPath
        else
          throw "modules/hosts/${name}/ has no meta.nix (see AGENTS.md)";
      unknown = lib.subtractLists hostKnobs (builtins.attrNames (m.dotfiles or { }));
    in
    assert lib.assertMsg (
      unknown == [ ]
    ) "modules/hosts/${name}/meta.nix: unknown dotfiles knob(s): ${lib.concatStringsSep ", " unknown}";
    m;

  # The identity every config built for a host carries; set after the host's own
  # knobs so a meta.nix cannot silently retarget a config's user or platform.
  identity =
    m:
    (m.dotfiles or { })
    // {
      username = m.username or "smores";
      system = m.system or "x86_64-linux";
    };

  mkHome =
    args:
    let
      system = args.system or "x86_64-linux";
      username = args.username or "smores";
    in
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForSystem system;
      extraSpecialArgs = {
        inherit inputs;
      };
      modules = homeModules ++ [
        {
          dotfiles = {
            inherit username;
          }
          // builtins.intersectAttrs homeKnobs args;
          home.username = username;
          home.homeDirectory =
            args.homeDirectory
              or (if lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}");
        }
      ];
    };

  mkNixos =
    args:
    let
      dm = args.displayManager or "none";
      username = args.username or "smores";
    in
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        { nixpkgs.overlays = localOverlays (args.system or "x86_64-linux"); }
      ]
      ++ nixosModules
      # hardware.nix is optional so a host can be authored (meta.nix +
      # disko.nix) before nixos-anywhere generates it during the install; the
      # guard keeps the flake evaluable in that window (see AGENTS.md).
      ++ lib.optional (builtins.pathExists (hostsDir + "/${args.hostname}/hardware.nix")) (
        hostsDir + "/${args.hostname}/hardware.nix"
      )
      ++ lib.optional (builtins.pathExists (hostsDir + "/${args.hostname}/disko.nix")) (
        hostsDir + "/${args.hostname}/disko.nix"
      )
      ++ [
        {
          networking.hostName = args.hostname;
          dotfiles = {
            inherit username;
            displayManager = dm;
            exposeSsh = args.exposeSsh or false;
            nvidia = args.nvidia or false;
            llm = args.llm or false;
            search = args.search or false;
            noSleep = args.noSleep or false;
            fingerprint = args.fingerprint or false;
            webProxy = args.webProxy or { };
            calibre = args.calibre or { };
            immich = args.immich or { };
            navidrome = args.navidrome or { };
            backup = args.backup or { };
            notify = args.notify or { };
          };
        }
      ]
      ++ lib.optionals (dm == "niri") [ niri.nixosModules.niri ];
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
          m = hostMeta name;
        in
        lib.nameValuePair "${m.username or "smores"}@${name}" (mkHome (identity m))
      ) (lib.filter (name: (hostMeta name).home or false) hostNames)
    );
    nixosConfigurations = lib.listToAttrs (
      map (name: lib.nameValuePair name (mkNixos ((identity (hostMeta name)) // { hostname = name; }))) (
        lib.filter (name: (hostMeta name).nixos or false) hostNames
      )
    );
  };
}
