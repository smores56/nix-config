{ inputs, nixpkgsFor, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    concord
    stylix
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
  ];

  # providers.nix injects `_module.args.aiProviders`, which options.nix's
  # computed defaults (e.g. dotfiles.defaultModel) depend on.  Pure data — safe
  # to import into NixOS evaluations too.
  nixosModules = [
    ../options.nix
    ../features/ai/providers.nix
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
    workHost = null;
  };
  homeArgs = [
    "system"
    "username"
    "homeDirectory"
  ];

  mkHome =
    args:
    let
      system = args.system or "x86_64-linux";
      username = args.username or "smores";
      # A typo'd or undeclared knob would otherwise vanish without a trace.
      unknown = lib.subtractLists (builtins.attrNames homeKnobs ++ homeArgs) (builtins.attrNames args);
    in
    assert lib.assertMsg (
      unknown == [ ]
    ) "mkHome: unknown arguments ${lib.concatStringsSep ", " unknown}; add them to homeKnobs";
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
      ++ [
        ../hosts/${args.hostname}.nix
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
    homeConfigurations = {
      "smores@smorestux" = mkHome {
        displayManager = "niri";
        nixos = true;
      };
      "smores@smoresbook" = mkHome {
        displayManager = "niri";
        nixos = true;
      };
      "smores@smorespro" = mkHome {
        displayManager = "niri";
        nixos = true;
        fingerprint = true;
        photobucket.enable = true;
      };
      "smores@campfire" = mkHome {
        displayManager = "niri";
        nixos = true;
        noSleep = true;
      };
      "smores@smortress" = mkHome {
        displayManager = "none";
        nixos = true;
        calibre.enable = true;
      };
      "sam@smoreswork" = mkHome {
        displayManager = "osx";
        windowManager = "aerospace";
        username = "sam";
        system = "aarch64-darwin";
        aiProfile = "work";
        workHost = true;
      };
    };
    nixosConfigurations = {
      "campfire" = mkNixos {
        hostname = "campfire";
        displayManager = "niri";
        exposeSsh = true;
        noSleep = true;
      };
      "smorestux" = mkNixos {
        hostname = "smorestux";
        displayManager = "niri";
      };
      "smoresbook" = mkNixos {
        hostname = "smoresbook";
        displayManager = "niri";
      };
      "smorespro" = mkNixos {
        hostname = "smorespro";
        displayManager = "niri";
        fingerprint = true;
      };
      "smortress" = mkNixos {
        hostname = "smortress";
        displayManager = "none";
        nvidia = true;
        llm = true;
        search = true;
        noSleep = true;
        webProxy = {
          enable = true;
          tunnelName = "smortress";
          services = {
            calibre.port = 8181;
            immich.port = 2283;
            # Unauthenticated loopback listener, so it must sit behind Access
            # (enforced by an assertion in modules/nixos/notify.nix).
            ntfy = {
              port = 2586;
              access.enable = true;
            };
          };
        };
        calibre.enable = true;
        immich.enable = true;
        # Relocated off /var/lib/immich so every media dataset lives under one
        # root (backup source and read-only server mounts both use it).
        immich.mediaLocation = "/var/lib/media/Photos";
        # These generic datasets replaced the old Immich-specific restic
        # pipeline, which has been removed.
        backup.enable = true;
        backup.datasets.Videos = {
          schedule = "*-*-* 01:00:00";
          # Seed-sized: 39G at Proton's ~1MB/s. T11 tightens this to 2h once
          # the first full upload has completed.
          timeout = "48h";
        };
        backup.datasets.Photos = {
          schedule = "*-*-* 03:00:00";
          timeout = "48h";
          # preBackup dumps Postgres, so the unit gets pg_dump on PATH and orders
          # after postgresql.service. Cache/credential excludes are the option
          # default, shared by every dataset.
          postgres = true;
          preBackup = ''
            mkdir -p "$BACKUP_CURRENT/db"
            tmp="$BACKUP_CURRENT/db/.immich-$BACKUP_DATE.tmp"
            # A dump killed mid-write must not leave a partial .tmp for the mirror
            # to pick up, so clean it on any exit or terminating signal.
            trap 'rm -f "$tmp"' EXIT
            trap 'rm -f "$tmp"; exit 1' TERM INT
            runuser -u postgres -- pg_dump -Fc --no-owner immich > "$tmp" \
              && mv "$tmp" "$BACKUP_CURRENT/db/immich-$BACKUP_DATE.dump" \
              || exit 1
          '';
        };
        backup.datasets.Music = {
          schedule = "*-*-* 05:00:00";
          timeout = "48h";
        };
        notify.enable = true;
      };
    };
  };
}
