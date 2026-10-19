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

  # Hosts are discovered from modules/hosts/<name>/; adding a host means adding
  # a directory (meta.nix + hardware.nix), never editing this file.
  hostsDir = ../hosts;
  hostNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir hostsDir)
  );
  # Top-level keys a host's meta.nix may author; anything else is a typo that
  # would otherwise be ignored silently (e.g. `homee` drops the home config).
  hostMetaKeys = [
    "dotfiles"
    "username"
    "system"
    "nixos"
    "home"
  ];
  hostMeta =
    name:
    let
      metaPath = hostsDir + "/${name}/meta.nix";
      m =
        if builtins.pathExists metaPath then
          import metaPath
        else
          throw "modules/hosts/${name}/ has no meta.nix (see AGENTS.md)";
      unknownTop = lib.subtractLists hostMetaKeys (builtins.attrNames m);
    in
    assert lib.assertMsg (unknownTop == [ ])
      "modules/hosts/${name}/meta.nix: unknown top-level key(s): ${lib.concatStringsSep ", " unknownTop} (allowed: ${lib.concatStringsSep ", " hostMetaKeys})";
    m;

  # Defaults for the identity keys every config needs; `dotfiles` is passed
  # through whole, so a typo is caught by the option system instead of a list.
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
          dotfiles = (args.dotfiles or { }) // {
            inherit username;
          };
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
      dm = args.dotfiles.displayManager or "none";
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
        {
          networking.hostName = args.hostname;
          # Host knobs are forwarded whole; an undeclared option fails
          # evaluation. The top-level identity is applied last so a meta.nix
          # cannot retarget the config's user or display manager.
          dotfiles = (args.dotfiles or { }) // {
            inherit username;
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
        lib.nameValuePair "${m.username or "smores"}@${name}" (mkHome (normalize m))
      ) (lib.filter (name: (hostMeta name).home or false) hostNames)
    );
    nixosConfigurations = lib.listToAttrs (
      map (name: lib.nameValuePair name (mkNixos ((normalize (hostMeta name)) // { hostname = name; }))) (
        lib.filter (name: (hostMeta name).nixos or false) hostNames
      )
    );
  };
}
